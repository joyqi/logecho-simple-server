
http = require 'http'
url = require 'url'
zlib = require 'zlib'
uuid = require 'node-uuid'
jade = require 'jade'
argv = require 'optimist'
    .default 'k', uuid.v4()
    .default 'h', '0.0.0.0'
    .default 'p', null
    .default 's', null
    .default '404', __dirname + '/../template/404.jade'
    .default '403', __dirname + '/../template/403.jade'
    .default '500', __dirname + '/../template/500.jade'
    .default '503', __dirname + '/../template/503.jade'
    .argv

data = null

message =
    403: 'Forbidden'
    404: 'Not Found'
    500: 'Internal Server Error'
    503: 'Service Unavailable'

mime =
    'html': 'text/html'
    'htm': 'text/html'
    'css': 'text/css'
    'js': 'application/x-javascript'
    'xml': 'text/xml'
    'gif': 'image/gif'
    'jpeg': 'image/jpeg'
    'jpg': 'image/jpeg'
    'jpe': 'image/jpeg'
    'tif': 'image/tiff'
    'tiff': 'image/tiff'
    'png': 'image/png'
    'svg': 'image/svg+xml'
    'svgz': 'image/svg+xml'
    'ico': 'image/x-icon'
    'txt': 'text/plain'
    'text': 'text/plain'

denied = []
retry = {}
pool = {}
CHECK_INTERVAL = 3000
RELEASE_INTERVAL = 5000


if not argv.p?
    argv.p = if argv.s? then 443 else 80


decode = (buff) ->
    lines = buff.split "\n"
    newData = {}

    for line in lines
        [path, v] = line.split ' '
        str = new Buffer v, 'base64'
            .toString 'utf8'
        
        parts = path.split '.'
        ext = parts[parts.length - 1].toLowerCase()
        type = if mime[ext] then mime[ext] else (if parts.length > 1 then 'text/plain' else 'application/octet-stream')
        suffix = null

        if type.match /^text\//
            suffix = '; charset=UTF-8'

        newData[path] =
            body: str
            ext: ext
            type: type
            suffix: suffix

    data = newData
    console.log '[' + (new Date().toISOString()) + '] publish success'


respond = (str, req, res) ->
    if (Number str) is str
        res.statusCode = str
        res.statusMessage = message[str]
        str = jade.renderFile argv[str + '']

    encoding = req.headers['accept-encoding']
    encoding = '' if not encoding
    encoding = encoding.split /\s*,\s*/
    pipe = res

    if 'deflate' in encoding
        res.setHeader 'Content-Encoding', 'deflate'
        pipe = zlib.createDeflate()
        pipe.pipe res
    else if 'gzip' in encoding
        res.setHeader 'Content-Encoding', 'gzip'
        pipe = zlib.createGzip()
        pipe.pipe res

    pipe.write str
    pipe.end()


dispatcher = (req, res) ->
    info = url.parse req.url, yes
    
    if req.method is 'GET'
        getHandler info, req, res
    else if req.method is 'POST'
        postHandler info, req, res


getHandler = (info, req, res) ->
    if not data?
        respond 503, req, res
        return

    path = info.pathname
    path += 'index.html' if path[path.length - 1] is '/'

    if data[path]?
        item = data[path]

        res.setHeader 'Content-Type', item.type + item.suffix
        respond item.body, req, res
    else
        respond 404, req, res


postHandler = (info, req, res) ->
    ip = req.connection.remoteAddress
    key = req.headers.authorization
    
    if ip in denied or not key?
        return respond 403, req, res
        

    key = (new Buffer (key.split ' ')[1], 'base64'
        .toString()
        .split ':')[0]

    if key is argv.k
        buff = ''

        req.on 'data', (chunk) ->
            buff += chunk.toString()

        req.on 'end', ->
            respond 'OK', req, res
            decode buff
    else
        respond 403, req, res
        retry[ip] = 0 if not retry[ip]?
        retry[ip] += 1
        pool[ip] = Date.now()
        denied.push ip if retry[ip] > 3 and ip not in denied


setInterval ->
    now = Date.now()

    for ip of retry
        if now - pool[ip] > RELEASE_INTERVAL
            delete retry[ip]
        else
            break

    for ip in denied
        if now - pool[ip] > RELEASE_INTERVAL
            denied.shift()
        else
            break

    for k, v of pool
        if now - pool[ip] > RELEASE_INTERVAL
            delete pool[ip]
        else
            break
, CHECK_INTERVAL


server = http.createServer dispatcher
module.exports = ->
    server.listen argv.p, argv.h
    console.log "The secure key is: #{argv.k}"
    console.log "Listening on #{argv.h}:#{argv.p}"

