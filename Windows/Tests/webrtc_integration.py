"""Real SDP/ICE/DTLS/RTP decode test against an isolated helper process.
Usage: python Windows/Tests/webrtc_integration.py --helper path/to/overlook-webrtc.exe
"""
import argparse
import asyncio
import os
from pathlib import Path
import struct
import sys

from aiortc import RTCPeerConnection, RTCConfiguration, RTCRtpSender, RTCSessionDescription, VideoStreamTrack
from av import VideoFrame


class Source(VideoStreamTrack):
    async def recv(self):
        pts, time_base = await self.next_timestamp()
        frame = VideoFrame(162, 96, 'yuv420p')
        for index, plane in enumerate(frame.planes):
            plane.update(bytes([80 if index == 0 else 128]) * plane.buffer_size)
        frame.pts, frame.time_base = pts, time_base
        return frame


async def verify(helper, codec, initiator):
    env = os.environ.copy()
    # Prove the bundled helper can run without Python or site-packages on PATH.
    env['PATH'] = str(Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32')
    env.pop('PYTHONPATH', None)
    env.pop('PYTHONHOME', None)
    command = [str(helper)] if helper.suffix == '.exe' else [sys.executable, str(helper)]
    process = await asyncio.create_subprocess_exec(*command, stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, env=env)
    peer = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    peer.addTrack(Source())
    selected = next(c for c in RTCRtpSender.getCapabilities('video').codecs if c.mimeType.lower() == f'video/{codec.lower()}')
    peer.getTransceivers()[0].setCodecPreferences([selected])

    async def send(kind, text='', line=0):
        payload = text.encode()
        process.stdin.write(struct.pack('<cII', kind, len(payload), line) + payload)
        await process.stdin.drain()

    async def receive(kind):
        while True:
            header = struct.unpack('<IIIII', await process.stdout.readexactly(20))
            payload = await process.stdout.readexactly(header[1])
            if header[0] == 3:
                raise AssertionError(payload.decode())
            if header[0] == kind:
                return header, payload

    try:
        if initiator == 'helper':
            await send(b'C')
            _, offer = await receive(2)
            await peer.setRemoteDescription(RTCSessionDescription(offer.decode(), 'offer'))
            await peer.setLocalDescription(await peer.createAnswer())
            await send(b'A', peer.localDescription.sdp)
        else:
            await peer.setLocalDescription(await peer.createOffer())
            # Strip candidates from the offer to exercise incoming trickle ICE.
            lines = peer.localDescription.sdp.splitlines()
            candidates = [line[2:] for line in lines if line.startswith('a=candidate:')]
            offer = '\r\n'.join(line for line in lines if not line.startswith(('a=candidate:', 'a=end-of-candidates'))) + '\r\n'
            await send(b'O', offer)
            _, answer = await receive(1)
            await peer.setRemoteDescription(RTCSessionDescription(answer.decode(), 'answer'))
            for candidate in candidates:
                await send(b'I', candidate)
        header, pixels = await receive(4)
        assert header[2:4] == (162, 96), header
        assert header[4] == 162 * 4, 'Frame rows must be packed without codec padding'
        assert len(pixels) == header[4] * 96
        assert pixels[3] == 255 and any(pixels[0:3]), 'Expected decoded BGRA pixels'
        print(f'PASS {codec}: {initiator} offer, real decoded frame, isolated runtime')
    finally:
        await peer.close()
        process.stdin.close()
        try:
            await asyncio.wait_for(process.wait(), 5)
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
        if process.returncode:
            print((await process.stderr.read()).decode(errors='replace'), file=sys.stderr)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--helper', type=Path, required=True)
    args = parser.parse_args()
    for codec in ['VP8', 'H264']:
        for initiator in ['peer', 'helper']:
            await asyncio.wait_for(verify(args.helper.resolve(), codec, initiator), 30)


if __name__ == '__main__':
    asyncio.run(main())

