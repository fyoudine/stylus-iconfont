stylus = require 'stylus'
path = require 'path'
fs = require 'fs'
Q = require 'q'

svgicons2svgfont = require 'svgicons2svgfont'
svg2ttf = require 'svg2ttf'
ttf2eot = require 'ttf2eot'
ttf2woff = require 'ttf2woff'
nodes = stylus.nodes
utils = stylus.utils

vendorDownloader = require './download'


class FontFactory
  constructor: (options)->

    @options = @updateOptions options
    @vendorMapping =
      'fa':
        path: "downloads/fontAwesome"
        name: "Font Awesome"
    @checkVendorDownloads @options if @options.autoDownloadVendor
    @startIndex = 0xF700
    @glyphsNames = []
    @glyphsInFont = []
    @allDone = []

  register: (style)=>
    style.define 'icon-font-name', new stylus.nodes.String @options.fontName
    style.define 'icon-font-unicode', @collectGlyphsNames
    style.define 'icon-font-font-face', @fontFace @options
    style.include __dirname
    return
  fontFace: (options)=>
    pathToFont = "#{options.fontFacePath.replace /\/$/, ''}/#{options.fontName}"
    ->
      new nodes.Literal """
        @font-face {
          font-family: '#{options.fontName}';
          src: url('#{pathToFont}.eot');
          src: url('#{pathToFont}.eot') format('embedded-opentype'), url('#{pathToFont}.woff') format('woff'), url('#{pathToFont}.ttf') format('truetype'), url('#{pathToFont}.svg') format('svg');
          font-weight: normal;
          font-style: normal;
        }
        """

  writeEotFile = (ttfBuffer, outputFile, log)->
    eot = ttf2eot new Uint8Array ttfBuffer
    eotBuffer = new Buffer eot.buffer
    fs.writeFileSync "#{outputFile}.eot", eotBuffer
    log? "[icon-font]: EOT font file created"

  writeWoffFile = (ttfBuffer, outputFile, log)->
    woff = ttf2woff new Uint8Array ttfBuffer
    woffBuffer = new Buffer woff.buffer
    fs.writeFileSync "#{outputFile}.woff", woffBuffer
    log? "[icon-font]: WOFF font file created"

  writeTtfFile = (ttfBuffer, outputFile, log)->
    fs.writeFileSync "#{outputFile}.ttf", ttfBuffer
    log? "[icon-font]: TTF font file created"

  checkVendorDownloads: ()=>
    @options.log? "[icon-font]: checking vendor downloads"
    for key, val of @vendorMapping
      if fs.existsSync "#{@options.glyphsDir}/#{val.path}"
        @vendorMapping[key].downloaded = true
        @options.log? "[icon-font]: #{val.name} found in '#{@options.glyphsDir}/#{val.path}'"


  run: =>
    @allDone = []
    for name, index in @glyphsNames
      item = codepoint: @startIndex + index, name: name, path: "#{@options.glyphsDir}/#{name}.svg"
      if @options.autoDownloadVendor
        item = @updateVendorPrefix item
        continue if item is false #need to be downloaded - so update will return false - that means that update is delayed and will be done in recheck part
      @allDone.push Q item
    @glyphsNames = []
    Q.all(@allDone).then (result)=>
      if result.length
        @options.log? "[icon-font]: Starting Write font Files"
        path = "#{@options.outputDir.replace /\/$/, ''}"
        @writeFiles result, path, "#{@options.fontName}"
      return

  updateOptions: (options)->
    options = options or {}
    ###
       svgicons2svgfont(options)
    ###
    options.fontName ?= 'iconfont'
    options.fixedWidth ?= false
    options.centerHorizontally ?= false
    options.normalize ?= true
    # options.fontHeight = Default value: MAX(icons.height)
    options.descent ?= 0
    options.log ?= false
    ###
       iconFont(options)
    ###
    #TODO find better solution
    options.glyphsDir ?= process.cwd()
    options.outputDir ?= process.cwd()
    options.fontFacePath ?= "/"
    options.watchMode ?= true
    options.autoDownloadVendor ?= true
    options.outputTypes ?= ['svg', 'ttf', 'eot', 'woff']
    return options

  collectGlyphsNames: (name)=>
    index = @glyphsNames.indexOf name.string
    if index < 0
      index = @glyphsNames.push name.string
    new nodes.Literal """#{name.quote}\\#{(@startIndex + @glyphsNames.indexOf name.string).toString(16)}#{name.quote}"""

  updateVendorPrefix: (item)=>
    segments = item.name.split "/"
    if segments.length > 1 and @vendorMapping.hasOwnProperty segments[0]
      # item.name = segments.join "-"
      item.path = "#{@options.glyphsDir}/#{@vendorMapping[segments[0]].path}/#{segments.slice(1).join "-"}.svg"
      if @vendorMapping[segments[0]].downloaded?
        item
      else
        deferred = Q.defer()
        @allDone.push deferred.promise
        @vendorMapping[segments[0]].delayed = [] if not @vendorMapping[segments[0]].delayed?
        @vendorMapping[segments[0]].delayed.push ->
          deferred.resolve item
        if not @vendorMapping[segments[0]].downloading and not @vendorMapping[segments[0]].downloaded
          @vendorMapping[segments[0]].downloading = true
          vendorDownloader segments[0], "#{@options.glyphsDir}/#{@vendorMapping[segments[0]].path}"
          .then =>
            @vendorMapping[segments[0]].downloading = false
            @vendorMapping[segments[0]].downloaded = true
            do func for func in @vendorMapping[segments[0]].delayed
            return
        false
    else
      item

  writeFiles: (glyphs, path, fontName)=>
    needToUpdate = no
    for glyph, index in glyphs
      if not fs.existsSync glyph.path
        @options.log "[icon-font]: File not found '#{glyph.path}'"
        glyphs.splice index, 1
      else
        if glyph.name not in @glyphsInFont
          @glyphsInFont.push glyph.name
          needToUpdate = yes
        glyph.stream = fs.createReadStream "#{glyph.path}"

    if not needToUpdate
      @options.log? "[icon-font]: Nothing to update"
      return
    else
      @glyphsNames = @glyphsInFont.slice()


    outputFile = "#{path}/#{fontName}"
    fontStream = svgicons2svgfont glyphs, @options
    .pipe fs.createWriteStream "#{outputFile}.svg"
    .on 'finish', =>
      @options.log? "[icon-font]: SVG font file created"
      ttf = svg2ttf fs.readFileSync("#{outputFile}.svg", encoding:"utf8"), {}
      ttfBuffer = new Buffer ttf.buffer
      if 'ttf' in @options.outputTypes
        writeTtfFile ttfBuffer, outputFile, @options.log
      if 'woff' in @options.outputTypes
        writeWoffFile ttfBuffer, outputFile, @options.log
      if 'eot' in @options.outputTypes
        writeEotFile ttfBuffer, outputFile, @options.log
    return

module.exports = FontFactory

module.exports.version = require(path.join(__dirname, 'package.json')).version
module.exports.path = __dirname