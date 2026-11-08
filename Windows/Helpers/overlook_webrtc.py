"""WebRTC receiver. stdin commands and stdout frames use a local binary pipe.
No device credentials are passed to this process. Requires requirements.txt.
"""
import asyncio
import json
import struct
import sys
import time

HEADER = struct.Struct('<IIIII')  # kind, payload bytes, width, height, stride
COMMAND = struct.Struct('<cII')   # command, payload bytes, media line


def packet(kind, payload=b'', width=0, height=0, stride=0):
    sys.stdout.buffer.write(HEADER.pack(kind, len(payload), width, height, stride))
    sys.stdout.buffer.write(payload)
    sys.stdout.buffer.flush()


def read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        part = stream.read(count - len(result))
        if not part:
            raise EOFError
        result.extend(part)
    return bytes(result)


async def main():
    from aiortc import RTCPeerConnection, RTCConfiguration, RTCIceServer, RTCSessionDescription
    from aiortc.sdp import candidate_from_sdp
    from aiortc.mediastreams import MediaStreamError

    pc = None
    tasks = set()
    pending_ice = []
    loopback_peers = []
    frames = 0
    dimensions = (0, 0)

    async def consume(track):
        nonlocal frames, dimensions
        try:
            while True:
                frame = await track.recv()
                if track.kind == 'video':
                    frame = frame.reformat(format='bgra')
                    frames += 1
                    dimensions = (frame.width, frame.height)
                    # Win32 DIBs and raw-video recording expect tightly packed BGRA.
                    # PyAV can pad scanlines (e.g. a 1366-pixel desktop).
                    plane = frame.planes[0]
                    row_bytes = frame.width * 4
                    pixels = memoryview(bytes(plane))
                    if plane.line_size == row_bytes:
                        pixels = pixels[:row_bytes * frame.height]
                    else:
                        pixels = b''.join(pixels[y * plane.line_size:y * plane.line_size + row_bytes]
                                          for y in range(frame.height))
                    packet(4, pixels, frame.width, frame.height, row_bytes)
        except MediaStreamError:
            pass
        except Exception as exc:
            packet(3, ('Video decode failed: ' + str(exc)).encode())

    async def create(stun=''):
        nonlocal pc
        if pc is None:
            servers = [RTCIceServer(urls=stun)] if stun else []
            pc = RTCPeerConnection(RTCConfiguration(iceServers=servers))

            @pc.on('track')
            def on_track(track):
                task = asyncio.create_task(consume(track))
                tasks.add(task)
                task.add_done_callback(tasks.discard)

            @pc.on('connectionstatechange')
            async def state_changed():
                if pc.connectionState == 'failed':
                    packet(3, b'WebRTC connection failed (ICE/DTLS). Check network reachability.')
        return pc

    async def remote(sdp, description_type):
        await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type=description_type))
        for candidate in pending_ice:
            await pc.addIceCandidate(candidate)
        pending_ice.clear()

    async def stats():
        last_frames, last_bytes, last_time = 0, 0, time.monotonic()
        while True:
            await asyncio.sleep(1)
            if pc is None or not frames:
                continue
            report = await pc.getStats()
            received = sum(getattr(item, 'bytesReceived', 0) for item in report.values() if item.type == 'transport')
            now = time.monotonic()
            duration = now - last_time
            data = dict(width=dimensions[0], height=dimensions[1], fps=round((frames-last_frames)/duration),
                        kbps=round(max(0, received-last_bytes)*8/duration/1000))
            packet(5, json.dumps(data).encode())
            last_frames, last_bytes, last_time = frames, received, now

    stats_task = asyncio.create_task(stats())
    try:
        while True:
            try:
                raw = await asyncio.to_thread(read_exact, sys.stdin.buffer, COMMAND.size)
                command, size, line = COMMAND.unpack(raw)
                if size > 1024 * 1024:
                    raise ValueError('Signaling message exceeds limit')
                value = (await asyncio.to_thread(read_exact, sys.stdin.buffer, size)).decode('utf-8')
            except EOFError:
                break
            await create(value if command == b'C' else '')
            if command == b'O':
                await remote(value, 'offer')
                await pc.setLocalDescription(await pc.createAnswer())
                packet(1, pc.localDescription.sdp.encode())
            elif command == b'C':
                pc.addTransceiver('video', direction='recvonly')
                await pc.setLocalDescription(await pc.createOffer())
                packet(2, pc.localDescription.sdp.encode())
            elif command == b'A':
                await remote(value, 'answer')
            elif command == b'T':
                # Real encoded RTP/ICE/DTLS loopback, not display-only test frames.
                from aiortc import VideoStreamTrack, RTCRtpSender
                from av import VideoFrame

                class TestVideo(VideoStreamTrack):
                    async def recv(self):
                        pts, time_base = await self.next_timestamp()
                        frame = VideoFrame(160, 96, 'yuv420p')
                        for index, plane in enumerate(frame.planes):
                            plane.update(bytes([80 if index == 0 else 128]) * plane.buffer_size)
                        frame.pts, frame.time_base = pts, time_base
                        return frame

                sender = RTCPeerConnection(RTCConfiguration(iceServers=[]))
                loopback_peers.append(sender)
                sender.addTrack(TestVideo())
                codec = next(c for c in RTCRtpSender.getCapabilities('video').codecs
                             if c.mimeType.lower() == ('video/h264' if value == 'H264' else 'video/vp8'))
                sender.getTransceivers()[0].setCodecPreferences([codec])
                await sender.setLocalDescription(await sender.createOffer())
                await remote(sender.localDescription.sdp, 'offer')
                await pc.setLocalDescription(await pc.createAnswer())
                await sender.setRemoteDescription(pc.localDescription)
            elif command == b'I':
                candidate = candidate_from_sdp(value.removeprefix('candidate:')) if value else None
                if candidate:
                    candidate.sdpMLineIndex = line
                if pc.remoteDescription is None:
                    pending_ice.append(candidate)
                else:
                    await pc.addIceCandidate(candidate)
            else:
                raise ValueError('Unknown signaling command')
    finally:
        stats_task.cancel()
        for task in tasks:
            task.cancel()
        if pc:
            await pc.close()
        for peer in loopback_peers:
            await peer.close()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except Exception as exc:
        packet(3, ('WebRTC helper: ' + str(exc) + '. Rebuild or reinstall the bundled WebRTC runtime.').encode())
        sys.exit(1)
