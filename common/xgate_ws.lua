local skynet = require "skynet"
local crypt = require "crypt"
local httpd = require "http.httpd"
local websocket = require "websocket"
local socket = require "socket"
local sockethelper = require "http.sockethelper"

local mainsvr = assert(tonumber(...))
local sessions = {}
local handler = {}
local CMD = {}

local function do_cleanup(ws)
    local session = sessions[ws.fd]
    if session then sessions[fd] = nil end
end

local function do_dispatchmsg(session, msg)
    local ok, msgdata = false, msg
    ok, msgdata = pcall(crypt.desdecode, session.secret, msgdata)
    if not ok then skynet.error("Des decode error, fd: "..session.ws.fd) return end
    ok, msgdata = pcall(crypt.base64decode(msgdata))
    if not ok then skynet.error("Base64 decode error: fd: ".. session.ws.fd) return end
    skynet.send(mainsvr, "client", session, msgdata)
end

local function do_verify(session, msg)
    local hmac = crypt.base64decode(msg)
    local verify = crypt.hmac64(session.challenge, session.secret)
    if hmac ~= verify then
        skynet.error("session("..session.ws.fd..") do verify error.")
        session.ws:close()
        return
    end
    session.proc = do_login
end

local function do_auth(session, msg)
    -- base64encode(8 bytes randomkey) is 12 bytes.
    if string.len(msg) == 12 then
        local cex = crypt.base64decode(msg)
        local skey = crypt.randomkey()
        local sex = crypt.dhexchange(skey)
        session.secret = crypt.dhsecret(cex, skey)
        session.ws:send_text(crypt.base64encode(sex))
        session.proc = do_verify
    else
        skynet.error("session("..session.ws.fd..") do auth error.")
        session.ws:close()
    end
end

local function do_handshake(session)
    session.challenge = crypt.randomkey()
    session.ws:send_text(crypt.base64encode(session.challenge))
    session.proc = do_auth
end

function handler.on_open(ws)
    local session = {
        fd = ws.fd,
        addr = ws.addr,
        ws = ws,
        challenge = nil,
        secret = nil,
        proc = nil
    }
    sessions[ws.fd] = session
    do_handshake(session)
end

function handler.on_close(ws, code, reason)
    do_cleanup(ws)
end

function handler.on_error(ws, msg)
    do_cleanup(ws)
end

function handler.on_message(ws, msg)
    local session = sessions[ws.fd]
    if session then
        session.proc(session, msg)
    else
        skynet.error("Unknown session("..ws.fd..").")
        ws:close()
    end
end

local function handle_socket(fd, addr)
    -- limit request body size to 8192 (you can pass nil to unlimit)
    local code, url, method, header, body = httpd.read_request(sockethelper.readfunc(fd), 8192)
    if code then
        if url == "/ws" then
            local ws = websocket.new(fd, addr, header, handler)
            ws:start()
        else
            socket.close(fd)
        end
    end
end

function CMD.open(address)
    local fd = assert(socket.listen(address))
    socket.start(fd , function(fd, addr)
        socket.start(fd)
        pcall(handle_socket, fd, addr)
    end)
    skynet.error("Listen on "..address)
end

function CMD.kick(fd)
    local session = sessions[fd]
    if session then
        session.ws:close()
    end
end

skynet.start(function() 
    skynet.dispatch("lua", function(_, _, cmd, ...)
        local f = CMD[cmd]
        if f then 
            skynet.ret(skynet.pack(f(...)))
        else
            skynet.error("Unknown command: "..cmd)
        end
    end)
end)