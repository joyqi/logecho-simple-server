
http = require 'http'
https = require 'https'
url = require 'url'
zlib = require 'zlib'
pathInfo = require 'path'
uuid = require 'node-uuid'
jade = require 'jade'
winston = require 'winston'
md5 = require 'MD5'
argv = require 'optimist'
    .default 'k', uuid.v4()
    .default 'h', '0.0.0.0'
    .default 'p', null
    .default '200', __dirname + '/../template/200.jade'
    .default '404', __dirname + '/../template/404.jade'
    .default '403', __dirname + '/../template/403.jade'
    .default '500', __dirname + '/../template/500.jade'
    .default '503', __dirname + '/../template/503.jade'
    .default 'prefer-host', null
    .default 'ip-address', null
    .default 'http-to-https', null
    .default 'https-key', null
    .default 'https-cert', null
    .default 'perform-resource', 'yes'
    .argv

logger = new winston.Logger
    transports: [
        new winston.transports.Console
            handleExceptions:   yes
            level:              'info'
            prettyPrint:        yes
            colorize:           yes
            timestamp:          yes
    ]
    exitOnError: no
    levels:
        info:   0
        warn:   1
        error:  3
    colors:
        info:   'green'
        warn:   'yellow'
        error:  'red'

data = null
isSecure = argv['https-key']? and argv['https-cert']?

message =
    200: 'OK'
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
CHECK_INTERVAL = 60000
RELEASE_INTERVAL = 86400000


if not argv.p?
    argv.p = if argv.s? then 443 else 80


performResource = (path, str, type, hashes) ->
    replace = (link) ->
        return link if link.match /^[_a-z0-9-]+:/i or link.match /^\/\//

        info = url.parse link
        dir = pathInfo.dirname path
        root = if path.match /^\./ then dir else ''
        normalizedPath = pathInfo.normalize root + info.pathname

        return link if not hashes[normalizedPath]?

        hash = hashes[normalizedPath]
        link = info.pathname + '?h=' + hash
        link += info.hash if info.hash?
        link

    switch type
        when 'text/html'
            str = str.replace /<link([^>]+)href="([^"]+)"([^>]*)>/ig, (m, a, link, b) ->
                link = replace link
                "<link#{a}href=\"#{link}\"#{b}>"
            str = str.replace /<img([^>]+)src="([^"]+)"([^>]*)>/ig, (m, a, link, b) ->
                link = replace link
                "<img#{a}src=\"#{link}\"#{b}>"
        when 'text/css'
            str = str.replace /url\(([^\)]+)\)/ig, (m, link) ->
                link = replace link
                "url(#{link})"
        else
            break
    str


decode = (buff, ip) ->
    lines = buff.split "\n"
    newData = {}
    hashes = {}

    for line in lines
        [path, v] = line.split ' '
        str = new Buffer v, 'base64'
            .toString 'utf8'
        
        ext = (pathInfo.extname path).substring 1
        type = if mime[ext] then mime[ext] else (if ext.length > 0 then 'text/plain' else 'application/octet-stream')
        suffix = null

        if type.match /^text\//
            suffix = '; charset=UTF-8'

        if argv['perform-resource'] is 'yes'
            hashes[path] = md5 v

        newData[path] =
            body: str
            type: type
            suffix: suffix
            time: new Date().toUTCString()
            cache: ext not in ['html', 'htm', 'xml', 'txt', 'text']

    if argv['perform-resource'] is 'yes'
        for path, item of newData
            newData[path].body = performResource path, item.body, item.type, hashes

    data = newData
    logger.info "Published contents form address #{ip}"


respond = (item, req, res) ->
    body = null
    cache = no

    if item not instanceof Object
        res.statusCode = item
        res.statusMessage = message[item]
        res.setHeader 'Content-Type', 'text/html; charset=UTF8'
        body = jade.renderFile argv[item + '']
    else
        res.setHeader 'Content-Type', item.type + item.suffix
        body = item.body
        cache = item.cache

    if cache
        res.setHeader 'Cache-Control', 'max-age=259200'
        res.setHeader 'Last-Modified', item.time
    else
        res.setHeader 'Cache-Control', 'no-store, no-cache, must-revalidate, post-check=0, pre-check=0'
        res.setHeader 'Pragma', 'no-cache'

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

    pipe.write body
    pipe.end()


dispatcher = (req, res) ->
    info = url.parse req.url, yes
    
    if req.method is 'GET'
        getHandler info, req, res
    else if req.method is 'POST'
        postHandler info, req, res


getHandler = (info, req, res) ->
    preferHost = argv['prefer-host']

    if preferHost?
        host = req.headers.host.split ':'
        if preferHost.toLowerCase() isnt host[0].toLowerCase()
            host[0] = preferHost
            redirectUrl = if isSecure then 'https' else 'http'
            redirectUrl += '://' + (host.join ':') + req.url

            res.statusCode = 301
            res.statusMessage = 'Moved Permanently'
            res.setHeader 'Location', redirectUrl

    if not data?
        respond 503, req, res
        return

    path = info.pathname
    path += 'index.html' if path[path.length - 1] is '/'

    if data[path]?
        respond data[path], req, res
    else
        respond 404, req, res


postHandler = (info, req, res) ->
    key = req.headers.authorization
    ip = req.connection.remoteAddress
    
    if argv['ip-address']?
        ip = req.headers[argv['ip-address'].toLowerCase()]
    
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
            respond 200, req, res
            decode buff, ip
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

if isSecure
    options =
        key: fs.readFileSync argv['https-key']
        cert: fs.readFileSync argv['https-cert']
    server = https.createServer options, dispatcher
else
    server = http.createServer dispatcher

module.exports = ->
    server.listen argv.p, argv.h
    
    logger.info "The secure key is: #{argv.k}"
    logger.info "Listening on #{argv.h}:#{argv.p}"
    logger.info "Http host is forcing to #{argv['prefer-host']}" if argv['prefer-host']?

    redirectPort = argv['http-to-https']
    if isSecure and redirectPort?
        redirectPort = if redirectPort is 'yes' then 80 else redirectPort
        
        http.createServer (req, res) ->
            redirectUrl = 'https://' + req.headers.host + req.url
            
            res.statusCode = 301
            res.statusMessage = 'Moved Permanently'
            res.setHeader 'Location', redirectUrl

