// Local aiortc process bridge. The UI thread owns command writes; a retained
// reader delivers decoded BGRA frames through the existing bounded frame queue.
static BOOL webrtc_read(HANDLE pipe, void *data, DWORD length) {
    BYTE *cursor=data;
    while(length) { DWORD count=0; if(!ReadFile(pipe,cursor,length,&count,NULL)||!count)return FALSE;cursor+=count;length-=count; }
    return TRUE;
}
static DWORD WINAPI webrtc_reader(void *context) {
    WebRTCWorker *worker=context; OLNative *n=worker->owner;
    for(;;) {
        uint32_t header[5];
        if(!webrtc_read(worker->output,header,sizeof(header)))break;
        uint32_t kind=header[0],length=header[1],w=header[2],h=header[3],stride=header[4];
        if(length>128*1024*1024 || (kind==4 && (!w||!h||w>8192||h>8192||stride<w*4||stride>65536||(uint64_t)stride*h!=length)))break;
        BYTE *payload=malloc((size_t)length+1);
        if(!payload)break;
        if(!webrtc_read(worker->output,payload,length)) {free(payload);break;}
        payload[length]=0;
        if(kind==4) deliver_bgra_frame(n,payload,(int)w,(int)h,(int)stride);
        else if(kind==1||kind==2||kind==3||kind==5) {
            if(kind==3)InterlockedExchange(&worker->failed,1);
            emit_event(n,kind==1 ? "answer" : kind==2 ? "local-offer" : kind==5 ? "stats" : "error",(char *)payload,0);
        }
        free(payload);
    }
    if(InterlockedCompareExchange(&n->active,0,0) && !worker->failed)
        emit_event(n,"error","Bundled WebRTC runtime stopped unexpectedly. Check the connection log and reinstall the complete app package.",0);
    EnterCriticalSection(&n->lock);
    InterlockedExchange(&worker->failed,1);
    if(worker->input) {CloseHandle(worker->input);worker->input=NULL;}
    CloseHandle(worker->output);worker->output=NULL;
    // If malformed output caused us to stop reading, do not leave a blocked child.
    TerminateProcess(worker->process,0);CloseHandle(worker->process);worker->process=NULL;
    LeaveCriticalSection(&n->lock);
    release_native(n);
    return 0;
}
static BOOL webrtc_start(OLNative *n) {
    if(n->webrtc)return !n->webrtc->failed;
    wchar_t script[MAX_PATH];
    GetModuleFileNameW(NULL,script,MAX_PATH);
    wchar_t *slash=wcsrchr(script,L'\\'); if(!slash)return FALSE;
    wcscpy_s(slash+1,MAX_PATH-(slash+1-script),L"webrtc\\overlook-webrtc.exe");
    if(GetFileAttributesW(script)==INVALID_FILE_ATTRIBUTES) {
        emit_event(n,"error","Missing bundled WebRTC runtime. Extract the complete app package, including the webrtc folder.",0);return FALSE;
    }
    SECURITY_ATTRIBUTES sa={sizeof(sa),NULL,TRUE};
    HANDLE input=NULL,childInput=NULL,output=NULL,childOutput=NULL;
    if(!CreatePipe(&childInput,&input,&sa,0)||!CreatePipe(&output,&childOutput,&sa,0))goto failed;
    SetHandleInformation(input,HANDLE_FLAG_INHERIT,0);SetHandleInformation(output,HANDLE_FLAG_INHERIT,0);
    wchar_t command[MAX_PATH*3];swprintf(command,MAX_PATH*3,L"\"%ls\"",script);
    STARTUPINFOW startup={0};startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESTDHANDLES;
    startup.hStdInput=childInput;startup.hStdOutput=childOutput;startup.hStdError=GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION process={0};
    if(!CreateProcessW(NULL,command,NULL,NULL,TRUE,CREATE_NO_WINDOW,NULL,NULL,&startup,&process))goto failed;
    CloseHandle(childInput);childInput=NULL;CloseHandle(childOutput);childOutput=NULL;CloseHandle(process.hThread);
    WebRTCWorker *worker=calloc(1,sizeof(*worker));
    if(!worker) {TerminateProcess(process.hProcess,1);CloseHandle(process.hProcess);goto failed;}
    worker->owner=n;worker->input=input;worker->output=output;worker->process=process.hProcess;n->webrtc=worker;
    retain_native(n);
    HANDLE thread=CreateThread(NULL,0,webrtc_reader,worker,0,NULL);
    if(!thread) {
        TerminateProcess(process.hProcess,1);CloseHandle(process.hProcess);n->webrtc=NULL;free(worker);release_native(n);goto failed;
    }
    CloseHandle(thread);return TRUE;
failed:
    if(input)CloseHandle(input);if(output)CloseHandle(output);
    if(childInput)CloseHandle(childInput);if(childOutput)CloseHandle(childOutput);
    emit_event(n,"error","Could not start bundled WebRTC runtime. Extract the complete app package, including the webrtc folder.",0);
    return FALSE;
}
static void webrtc_command(OLNative *n,char command,const char *text,uint32_t line) {
    if(!n||!InterlockedCompareExchange(&n->active,0,0)||!webrtc_start(n))return;
    if(!text)text="";
    size_t size=strlen(text);if(size>1024*1024) {emit_event(n,"error","WebRTC signaling message exceeds limit",0);return;}
    // Explicit byte layout avoids compiler struct padding.
    BYTE *packet=malloc(size+9);if(!packet)return;
    uint32_t length=(uint32_t)size;packet[0]=(BYTE)command;
    memcpy(packet+1,&length,4);memcpy(packet+5,&line,4);memcpy(packet+9,text,size);
    BOOL ok=FALSE;DWORD written=0;
    EnterCriticalSection(&n->lock);
    if(n->webrtc->input && !n->webrtc->failed)
        ok=WriteFile(n->webrtc->input,packet,(DWORD)(size+9),&written,NULL) && written==size+9;
    LeaveCriticalSection(&n->lock);free(packet);
    if(!ok && !n->webrtc->failed)emit_event(n,"error","Could not send signaling to WebRTC helper",0);
}
void ol_native_offer(OLNative *n,const char *sdp) {webrtc_command(n,'O',sdp,0);}
void ol_native_create_offer(OLNative *n,const char *stun) {webrtc_command(n,'C',stun,0);}
void ol_native_answer(OLNative *n,const char *sdp) {webrtc_command(n,'A',sdp,0);}
void ol_native_ice(OLNative *n,unsigned int line,const char *candidate) {webrtc_command(n,'I',candidate,line);}
