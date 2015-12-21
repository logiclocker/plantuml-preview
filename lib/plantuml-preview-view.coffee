{$, ScrollView} = require 'atom-space-pen-views'
{Disposable, CompositeDisposable, BufferedProcess} = require 'atom'
clipboard = null
nativeimage = null
path = null
fs = null
os = null
beautify_html = null

editorForId = (editorId) ->
  for editor in atom.workspace.getTextEditors()
    return editor if editor.id?.toString() is editorId.toString()
  null

settingsError = (message, setting) ->
  options = {
    detail: "Verify '#{setting}' in settings.",
    buttons: [{
        text: 'Open Package Settings',
        onDidClick: -> atom.workspace.open('atom://config/packages/plantuml-preview', searchAllPanes: true)
    }],
    dismissable: true
  }
  atom.notifications.addError "plantuml-preview: #{message}", options

module.exports =
class PlantumlPreviewView extends ScrollView
  @content: ->
    @div class: 'plantuml-preview padded pane-item', tabindex: -1, =>
      @div class: 'plantuml-control', outlet: 'control', =>
        @div =>
          @input id: 'zoomToFit', type: 'checkbox', outlet: 'zoomToFit'
          @label 'Zoom To Fit'
        @div =>
          @input id: 'useTempDir', type: 'checkbox', outlet: 'useTempDir'
          @label 'Use Temp Dir'
        @div =>
          @label 'Output'
          @select outlet: 'outputFormat', =>
            @option value: 'png', 'png'
            @option value: 'svg', 'svg'
      @div class: 'plantuml-container', outlet: 'container'

  constructor: ({@editorId}) ->
    super
    @editor = editorForId @editorId
    @disposables = new CompositeDisposable
    @imageInfo = {scale: 1}

  destroy: ->
    @disposables.dispose()

  attached: ->
    if @editor?
      @useTempDir.attr('checked', atom.config.get('plantuml-preview.useTempDir'))
      @outputFormat.val atom.config.get('plantuml-preview.outputFormat')

      @zoomToFit.attr('checked', atom.config.get('plantuml-preview.zoomToFit'))
      checkHandler = (checked) =>
        @setZoomFit(checked)
      @on 'change', '#zoomToFit', ->
        checkHandler(@checked)

      saveHandler = =>
        @renderUml()
      @disposables.add @editor.getBuffer().onDidSave ->
        saveHandler()

      if atom.config.get 'plantuml-preview.bringFront'
        @disposables.add atom.workspace.onDidChangeActivePaneItem (item) =>
          if item is @editor
            pane = atom.workspace.paneForItem(this)
            if (typeof(pane) != 'undefined') && (pane != null)
              pane.activateItem this

      atom.commands.add @element,
        'plantuml-preview:zoom-in': =>
          @imageInfo.scale = @imageInfo.scale * 1.1
          @scaleImages()
        'plantuml-preview:zoom-out': =>
          @imageInfo.scale = @imageInfo.scale * 0.9
          @scaleImages()
        'plantuml-preview:zoom-reset': =>
          @imageInfo.scale = 1
          @scaleImages()
        'plantuml-preview:zoom-fit': =>
          @zoomToFit.prop 'checked', !@zoomToFit.is(':checked')
          @setZoomFit @zoomToFit.is(':checked')
        'core:copy': (event) =>
          event.stopPropagation()
          filename = $(event.target).closest('.uml-image').attr('file')
          switch path.extname(filename)
            when '.png'
              nativeimage ?= require 'native-image'
              clipboard ?= require 'clipboard'
              buffer = fs.readFileSync(filename)
              image = nativeimage.createFromBuffer(buffer)
              clipboard.writeImage(image)
            when '.svg'
              buffer = fs.readFileSync(filename, @editor.getEncoding())
              if atom.config.get 'plantuml-preview.beautifyXml'
                beautify_html ?= require('js-beautify').html
                buffer = beautify_html buffer
              atom.clipboard.write(buffer)
            else
              atom.notifications.addError "plantuml-preview: Unsupported File Format", detail: "#{ext} is not currently supported by 'Copy Diagram'."
        'plantuml-preview:open-file': (event) =>
          filename = $(event.target).closest('.open-file').attr('file')
          atom.workspace.open filename


      @renderUml()

  getPath: ->
    if @editor?
      @editor.getPath()

  getURI: ->
    if @editor?
      "plantuml-preview://editor/#{@editor.id}"

  getTitle: ->
    if @editor?
      "#{@editor.getTitle()} Preview"

  onDidChangeTitle: ->
    new Disposable()

  onDidChangeModified: ->
    new Disposable()

  addImages: (imgFiles, time) ->
    @container.empty()
    displayFilenames = atom.config.get('plantuml-preview.displayFilename')
    for file in imgFiles
      if displayFilenames
        div = $('<div/>')
          .attr('class', 'filename open-file')
          .attr('file', file)
          .text("#{file}")
        @container.append div
      imageInfo = @imageInfo
      zoomToFit = @zoomToFit.is(':checked')
      img = $('<img/>')
        .attr('src', "#{file}?time=#{time}")
        .attr('file', file)
        .load ->
          img = $(this)
          file = img.attr 'file'
          name = path.basename file, path.extname(file)
          if imageInfo.hasOwnProperty name
            info = imageInfo[name]
          else
            info = {}
          info.origWidth = img.width()
          info.origHeight = img.height()
          imageInfo[name] = info

          img.attr('width', imageInfo.scale * info.origWidth)
          img.attr('height', imageInfo.scale * info.origHeight)
          img.addClass('uml-image')
          img.addClass('open-file')
          if zoomToFit
            img.addClass('zoomToFit')

      @container.append img
    @container.show

  scaleImages: ->
    for e in @container.find('.uml-image')
      img = $(e)
      file = img.attr 'file'
      name = path.basename file, path.extname(file)
      img.attr 'width', @imageInfo.scale * @imageInfo[name].origWidth
      img.attr 'height', @imageInfo.scale * @imageInfo[name].origHeight
    @zoomToFit.prop 'checked', false
    @setZoomFit @zoomToFit.is(':checked')

  removeImages: ->
    @container.empty()
    @container.append $('<div/>').attr('class', 'throbber')
    @container.show

  setZoomFit: (checked) ->
    if checked
      @container.find('.uml-image').addClass('zoomToFit')
    else
      @container.find('.uml-image').removeClass('zoomToFit')

  getFilenames: (directory, defaultName, defaultExtension, contents) ->
    path ?= require 'path'
    filenames = []
    defaultFilename = path.join(directory, defaultName)
    defaultCount = 0
    for uml in contents.split(///@enduml///i)
      if uml.trim() == ''
        continue

      currentFilename = path.join(directory, defaultName)
      currentExtension = defaultExtension
      pageCount = 1

      filename = uml.match ///@startuml([^\n]*)\n///i
      if filename?
        filename = filename[1].trim()
        if filename != ''
          if path.extname(filename)
            currentExtension = path.extname filename
          else
            currentExtension = defaultExtension
          currentFilename = path.join(directory, filename.replace(currentExtension, ''))

      if (currentFilename == defaultFilename)
        if defaultCount > 0
          countStr = defaultCount + ''
          countStr = '000'.substring(countStr.length) + countStr
          newfile = "#{currentFilename}_#{countStr}#{currentExtension}"
          filenames.push(newfile) unless newfile in filenames
        else
          newfile = currentFilename + currentExtension
          filenames.push(newfile) unless newfile in filenames
        defaultCount++
      else
        newfile = currentFilename + currentExtension
        filenames.push(newfile) unless newfile in filenames

      for line in uml.split('\n')
        if line.match ///^[\s]*(newpage)///i
          countStr = pageCount + ''
          countStr = '000'.substring(countStr.length) + countStr
          newfile = "#{currentFilename}_#{countStr}#{currentExtension}"
          filenames.push(newfile) unless newfile in filenames
          pageCount++

    filenames

  renderUml: ->
    path ?= require 'path'
    fs ?= require 'fs-plus'
    os ?= require 'os'

    filePath = @editor.getPath()
    basename = path.basename(filePath, path.extname(filePath))
    directory = path.dirname(filePath)
    format = @outputFormat.val()

    if @useTempDir.is(':checked')
      directory = path.join os.tmpdir(), 'plantuml-preview'
      if !fs.existsSync directory
        fs.mkdirSync directory

    imgFiles = @getFilenames directory, basename, '.' + format, @editor.getText()

    upToDate = true
    fileTime = fs.statSync(filePath).mtime
    for image in imgFiles
      if fs.isFileSync(image)
        if fileTime > fs.statSync(image).mtime
          upToDate = false
          break
      else
        upToDate = false
        break
    if upToDate
        @removeImages()
        @addImages imgFiles, Date.now()
        return

    command = atom.config.get 'plantuml-preview.java'
    args = [
      '-jar',
      atom.config.get('plantuml-preview.jarLocation'),
      '-charset',
      @editor.getEncoding()
    ]
    if format == 'svg'
      args.push '-tsvg'
    dotLocation = atom.config.get('plantuml-preview.dotLocation')
    if dotLocation != ''
      if fs.isFileSync dotLocation
        args.push '-graphvizdot', dotLocation
      else
        settingsError "#{dotLocation} not found or is not a file.", 'Graphviz Dot Location'
    args.push '-output', directory, filePath

    outputlog = []
    errorlog = []

    exitHandler = (files) =>
      if atom.config.get('plantuml-preview.beautifyXml') and (format == 'svg')
        beautify_html ?= require('js-beautify').html
        for file in imgFiles
          buffer = fs.readFileSync(file, @editor.getEncoding())
          buffer = beautify_html buffer
          fs.writeFileSync(file, buffer, {encoding: @editor.getEncoding()})
      @addImages(files, Date.now())
      if errorlog.length > 0
        str = errorlog.join('')
        if str.match ///jarfile///i
          settingsError str, 'PlantUML Jar Location'
        else
          atom.notifications.addError "plantuml-preview: stderr (logged to console)", detail: str
          console.log "plantuml-preview: stderr\n#{str}"
      if outputlog.length > 0
        str = outputlog.join('')
        atom.notifications.addInfo "plantuml-preview: stdout (logged to console)", detail: str
        console.log "plantuml-preview: stdout\n#{str}"
    exit = (code) ->
      exitHandler imgFiles

    stdout = (output) ->
      outputlog.push output
    stderr = (output) ->
      errorlog.push output
    errorHandler = (object) ->
      object.handle()
      settingsError "#{command} not found.", 'Java Command'

    @removeImages()
    new BufferedProcess({command, args, stdout, stderr, exit}).onWillThrowError errorHandler
