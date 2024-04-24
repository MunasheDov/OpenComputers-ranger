local version = 0.2
local component = require("component")
local shell = require("shell")
local term = require("term")
local text = require("text")
local keyboard = require("keyboard")
local event = require("event")
local fs = require("filesystem")
local serialize = require("serialization").serialize
local gpu = term.gpu()

local helpstring = "[m]ake, [r]ename, [y/p] yank/paste, [e]dit, run [a]rgs, home [/], [g]oto, [s]hell"

local config = {
	outlines = true,
	logging = false,
	timing = false,
	scrollSpeed = 8,
}

function getLogger(filename, tag)
	logfile, err = io.open(filename, "w")
	if err then
		error(err)
	end
	if tag then tag = tag.." " else tag = "" end
	return function(...)
		logfile:write(tag)
		for i,v in ipairs({...}) do
			logfile:write(tostring(v))
		end
		logfile:write("\n")
		logfile:flush()
	end
end

local log = getLogger("/home/log", "[ranger]")
if not config.logging then log = function(...) return end end

logvar = function(k, v)
	log(string.format("%s: %s: %s", debug.getinfo(3).name or "anonymous", k, serialize(v)))
end

function table.indexOf(t, object)
    if type(t) ~= "table" then error("table expected, got " .. type(t), 2) end
    for i, v in pairs(t) do
        if object == v then
            return i
        end
    end
end

function clamp(low, val, high)
	if val < low then return low end
	if val > high then return high end
	return val
end

local color = {
	dir = 0x70b0ff, --0xa0a0ff,
	lua = 0x40ff40,
	plain = 0xffffff,
	bg = 0x0,
	border = 0x202020,
	currentDirectory = 0xffff00,
}

local w, h = gpu.getResolution()

local parentFile, selectedFile
local top
if config.outlines then top = 2 else top = 1 end
local bottom = h - 3
local cursorIndex = 1

local function extension(path)
	return string.match(path, "[^.]+$") or ""
end

local function setColorByFileType(fname)
	if fname:find("/$") then
		gpu.setForeground(color.dir, false)
	elseif extension(fname) == "lua" then
		gpu.setForeground(color.lua, false)
	else
		gpu.setForeground(color.plain)
	end
end

local col = {}
col.left = {x = 1, iw = math.floor(w/6)}
col.mid = {x = col.left.x + col.left.iw - 1, iw = math.floor(w/3)}
col.right = {x = col.mid.x + col.mid.iw - 1}
col.right.iw = w - col.right.x

col.left.rows = {}
col.mid.rows = {}
col.right.rows = {}

col.left.scrollY = 0
col.mid.scrollY = 0
col.right.scrollY = 0

function setInfoText(...)
	gpu.fill(1,h-2,w,1," ")
	term.setCursor(1,h-2)
	gpu.set(1,h-2, tostring(...))
end

function drawFilenameIndexed(column, index, inverted)
	if type(index) ~= "number" then error(debug.traceback().." non-number index passed to drawFilenameIndexed for column "..table.indexOf(col, column)) end
	local filename = column.rows[index]
	local y = top + index - (column.scrollY or 0)
	if y > bottom then log(string.format("drawFilenameIndexed tried to draw %s off of bottom (%d)", filename, y)) end
	setColorByFileType(filename)
	if inverted then
		local bg = gpu.setBackground(gpu.getForeground(), false)
		gpu.setForeground(bg, false)
	end
	gpu.fill(column.x, y, column.iw-2, 1, " ")
	local overrun = column.iw-4 - #filename
	if overrun < 0 then
		gpu.set(column.x+1, y, filename:sub(1, #filename + overrun))
		gpu.set(column.x+column.iw-4, y, "~")
	else
		gpu.set(column.x+1, y, filename)
	end
	gpu.setBackground(color.bg, false)
	gpu.setForeground(color.plain, false)
end

function drawFilename(column, filename, inverted)
	local index = table.indexOf(column.rows, filename)
	if not index then error(debug.traceback() .. string.format(" failed to find '%s' in column %s (%d)", filename, table.indexOf(col, column), #column.rows)) end
	drawFilenameIndexed(column, index, inverted)
end

function drawPreview(buffered)
	local previewHeight = bottom - top - 1
	if not buffered then gpu.fill(col.right.x, top+1, w-col.right.x + 1, previewHeight - 1, " ") end
	col.right.rows = {}
	if not selectedFile then error("selectedFile is nil in drawPreview()") end
	local cwd = shell.getWorkingDirectory()
	local path = cwd.."/"..selectedFile
	if fs.isDirectory(path) then
		for f in fs.list(path) do table.insert(col.right.rows, f) end
		for i,_ in ipairs(col.right.rows) do
			if i == previewHeight then break end
			drawFilenameIndexed(col.right, i)
		end
	else
		gpu.setForeground(color.plain, false)
		local cx,cy = col.right.x, top
		local f, err = io.open(cwd.."/"..selectedFile)
		if not f then setInfoText(err); return end
		for line in f:lines() do
			cy = cy + 1
			if cy > previewHeight then break end
			term.setCursor(cx, cy)
			term.write(line, false)
		end
		f:close()
	end
end



function moveLeft()
	local cwd = shell.getWorkingDirectory()
	logvar("cwd", cwd)
	if cwd == "/" then
		setInfoText("already root")
		return
	end
	
	selectedFile = fs.name(cwd).."/"
	logvar("selectedFile", selectedFile)
	--log("moveLeft: selectedFile " ..selectedFile)
	local parentDirectory = shell.resolve(cwd.."/..")
	logvar("parentDirectory", parentDirectory)
	
	shell.setWorkingDirectory(parentDirectory)
	local grandparentDirectory = shell.resolve(parentDirectory.."/..")
	logvar("grandparentDirectory", grandparentDirectory)
	
	cursorIndex = table.indexOf(col.left.rows, selectedFile)
	logvar("cursorIndex", cursorIndex)
	col.mid.scrollY = 0
	
	col.right.rows = col.mid.rows
	col.mid.rows = col.left.rows
	col.left.rows = {}
	if grandparentDirectory == parentDirectory then
		col.left.rows = {"/"}
	else
		for f in fs.list(grandparentDirectory) do table.insert(col.left.rows, f) end
	end
	logvar("col.left.rows", col.left.rows)
	parentFile = fs.name(parentDirectory)
	logvar("parentFile", parentFile)
	if parentFile == nil then
		parentFile = "/"
	else
		parentFile = parentFile.."/"
	end
	-- better redrawing should go here
	return true
end

function moveRight()
	local cwd = shell.getWorkingDirectory()
	local path = cwd.."/"..selectedFile
	if not fs.isDirectory(path) then return end
	local fileHasChild = false
	for f in fs.list(path) do fileHasChild = true; break end
	if not fileHasChild then return end
	
	col.left.rows = col.mid.rows
	col.mid.rows = col.right.rows
	col.right.rows = {}
	
	parentFile = selectedFile
	cursorIndex = clamp(1, cursorIndex, #col.mid.rows)
	selectedFile = col.mid.rows[cursorIndex]
	
	shell.setWorkingDirectory(path)
	for f in fs.list(path) do table.insert(col.right.rows, f) end
	return true
end

function update()
	local cwd = shell.getWorkingDirectory()
	col.left.rows = {}
	local leftpath = shell.resolve(cwd.."/..")
	for f in fs.list(leftpath) do table.insert(col.left.rows, f) end
	
	local seg = fs.segments(cwd)
	if #seg == 0 then
		parentFile = "/"
	elseif #seg > 1 then
		parentFile = seg[#seg] .. "/"
	else
		parentFile = seg[1] .. "/"
	end
	if parentFile == "/" then col.left.rows = {"/"} end
	
	col.mid.rows = {} -- prv = {}
	
	for f in fs.list(cwd) do table.insert(col.mid.rows, f) end
	selectedFile = col.mid.rows[cursorIndex]
	if not selectedFile then cursorIndex = 1; selectedFile = col.mid.rows[cursorIndex] end
end

gpu.freeAllBuffers()
local backbuffer = gpu.allocateBuffer(w, h)

gpu.clear = function() gpu.fill(1,1,w,h," ") end
gpu.clearLine = function(ln) gpu.fill(1,ln,w,1," ") end

function redraw()
	if backbuffer ~= 1 then error("backbuffer is invalid "..tostring(backbuffer)) end
	gpu.setActiveBuffer(backbuffer)
	gpu.clear()

	for i=1,math.min(#col.left.rows, bottom-top-1) do
		drawFilenameIndexed(col.left, i)
	end
	if parentFile == nil then error(debug.traceback().. " parentFile is nil in redraw") end
	drawFilename(col.left, parentFile, true)
	for i=1+col.mid.scrollY,math.min(#col.mid.rows, bottom-top+col.mid.scrollY) do
		drawFilenameIndexed(col.mid, i)
	end
	drawFilename(col.mid, selectedFile, true)
	drawPreview(true)
	
	gpu.clearLine(1)
	gpu.setForeground(color.currentDirectory)
	gpu.set(1,1, shell.getWorkingDirectory())
	gpu.setForeground(color.plain)
	local dateString = os.date()
	gpu.set(w-#dateString-1, 1, dateString)
	
	
	local y = h
	if #helpstring > w then y = y - 1 end
	gpu.setForeground(color.border, false)
	gpu.set(1,y, helpstring)
	gpu.setForeground(color.plain, false)
	
	if config.outlines then
	-- draw outlines
	
	-- top outlines
	local verticalLineChar = "│"
		gpu.setForeground(color.border)
		gpu.fill(col.left.iw-1, top+1, 1, bottom-top, verticalLineChar)
		gpu.fill(col.mid.x + col.mid.iw-2, top+1, 1, bottom-top, verticalLineChar)
		
		local horizontalLineChar = "─"
		gpu.fill(1, top, w, 1, horizontalLineChar)
		
		local Tchar = "┬"
		gpu.set(col.left.iw-1, top, Tchar)
		gpu.set(col.mid.x + col.mid.iw-2, top, Tchar)
		
		-- bottom outlines
		gpu.fill(1, bottom, w, 1, horizontalLineChar)
		local TcharInverted = "┴"
		gpu.set(col.left.iw-1, bottom, TcharInverted)
		gpu.set(col.mid.x + col.mid.iw-2, bottom, TcharInverted)
	end
	
	gpu.bitblt(0, 1,1,w,h, backbuffer, 1,1)
	gpu.setActiveBuffer(0)
end

function refresh()
	update()
	redraw()
end

function confirmation(query)
	setInfoText(query.." [Y/n]")
	local id, _, character, code = event.pull("key_down")
	local c = string.char(character)
	if code == keyboard.keys.enter or c == "Y" or c == "y" then
		return true
	elseif code == keyboard.keys.back or c == "N" or c == "n" then
		return false
	end
end

function moveCursor(delta)
	local previousCursorIndex = cursorIndex
	cursorIndex = cursorIndex + delta
	cursorIndex = clamp(1, cursorIndex, #col.mid.rows)
	if cursorIndex == previousCursorIndex then return end
	drawFilenameIndexed(col.mid, previousCursorIndex)
	if cursorIndex <= col.mid.scrollY then
		gpu.copy(col.mid.x, top, col.mid.iw-2, bottom-top-1, 0,1)
		col.mid.scrollY = col.mid.scrollY - 1
	elseif cursorIndex - col.mid.scrollY == bottom-top then
		gpu.copy(col.mid.x, top+2, col.mid.iw-2, bottom-top-1, 0,-1)
		col.mid.scrollY = col.mid.scrollY + 1
	end
	selectedFile = col.mid.rows[cursorIndex]
	drawFilenameIndexed(col.mid, cursorIndex, true)
	drawPreview()
end

local screenBuffer = 0
function frameStash()
	gpu.bitblt(backbuffer, 1,1,w,h, screenBuffer, 1,1)
	gpu.clear()
	term.setCursor(1,1)
end
function frameRestore()
	gpu.bitblt(screenBuffer, 1,1,w,h, backbuffer, 1,1)
end

if config.timing then
	local ISEC_TO_TICKS = 1000/60/60
	p_refresh = refresh
	refresh = function(...)
		local t = os.time()
		p_refresh(...)
		local dt = os.difftime(os.time(), t) * ISEC_TO_TICKS
		setInfoText(string.format("refresh: %.0f ticks", dt))
	end

	p_moveCursor = moveCursor
	moveCursor = function(...)
		local t = os.time()
		p_moveCursor(...)
		local dt = os.difftime(os.time(), t) * ISEC_TO_TICKS
		setInfoText(string.format("moveCursor: %.0f ticks", dt))
	end

	p_moveLeft = moveLeft
	moveLeft = function(...)
		local t = os.time()
		p_moveLeft(...)
		local dt = os.difftime(os.time(), t) * ISEC_TO_TICKS
		setInfoText(string.format("moveLeft: %.0f ticks", dt))
	end

	p_moveRight = moveRight
	moveRight = function(...)
		local t = os.time()
		p_moveRight(...)
		local dt = os.difftime(os.time(), t) * ISEC_TO_TICKS
		setInfoText(string.format("moveRight: %.0f ticks", dt))
	end
end
refresh()
while true do
	::continue::
	local id, keyboardAddress, character, code, playerName = event.pullMultiple("interrupted", "key_down", "touch", "scroll")
	setInfoText("")
	selectedFile = col.mid.rows[cursorIndex]
	if not selectedFile then cursorIndex = 1; selectedFile = col.mid.rows[cursorIndex] end
	
	if id == "interrupted" then
		term.clear()
		term.setCursor(1,1)
		print("exited")
		break
	elseif id == "scroll" then
		local delta = playerName
		if #col.mid.rows < bottom-top then
			goto continue
		end
		local psY = col.mid.scrollY
		col.mid.scrollY = clamp(0, col.mid.scrollY - delta * config.scrollSpeed, #col.mid.rows - bottom+top+1)
		local scrollDelta = psY - col.mid.scrollY
		if scrollDelta ~= 0 then
			redraw()
		end
	elseif id == "touch" then
		local x,y = character, code
		if y > top and y < bottom then
			if x < col.mid.x then -- left column
				if y - top <= #col.left.rows then
					local clickedFile = col.left.rows[y-top]
					if moveLeft() then
						selectedFile = clickedFile
						cursorIndex = y-top
						redraw()
					end
				end
			elseif x < col.mid.x + col.mid.iw-2 then -- mid column
				if y - top <= #col.mid.rows then
					local prvcursorIndex = cursorIndex
					cursorIndex = y - top + col.mid.scrollY
					if prvcursorIndex == cursorIndex then
						event.push("key_down", term.keyboard(), 0, keyboard.keys.enter)
					else
						selectedFile = col.mid.rows[cursorIndex]
						drawFilenameIndexed(col.mid, prvcursorIndex)
						drawFilename(col.mid, selectedFile, true)
						drawPreview()
					end
				end
			else -- right column
				if y - top <= #col.right.rows then
					local clickedFile = col.right.rows[y-top]
					if moveRight() then
						selectedFile = clickedFile
						cursorIndex = y-top
						redraw()
					end
				end
			end
		end
	elseif id == "key_down" then
		local c = string.char(character)
		local cwd = shell.getWorkingDirectory()
		local path = cwd.."/"..selectedFile
		if c == "k" or code == keyboard.keys.up then
			moveCursor(-1)
		elseif c == "j" or code == keyboard.keys.down then
			moveCursor(1)
		elseif c == "h" or code == keyboard.keys.left then
			moveLeft()
			local ok, err = pcall(redraw)
			if not ok then
				gpu.setActiveBuffer(0)
				term.clear()
				log(err)
				os.exit()
			end
		elseif c == "l" or code == keyboard.keys.right then
			moveRight()
			redraw()
		elseif code == keyboard.keys.home and cursorIndex ~= 1 then
			--moveCursor(-cursorIndex+1)
			local prvcursorIndex = cursorIndex
			cursorIndex = 1
			selectedFile = col.mid.rows[cursorIndex]
			if col.mid.scrollY > 0 then
				col.mid.scrollY = 0
				redraw()
			else
				drawFilenameIndexed(col.mid, prvcursorIndex)
				drawFilename(col.mid, selectedFile, true)
				drawPreview(false)
			end
		elseif code == keyboard.keys["end"] and cursorIndex ~= #col.mid.rows then
			local prvcursorIndex = cursorIndex
			cursorIndex = #col.mid.rows
			selectedFile = col.mid.rows[cursorIndex]
			if #col.mid.rows >= bottom-top then
				col.mid.scrollY = #col.mid.rows - (bottom-top-1)
				redraw()
			else
				drawFilenameIndexed(col.mid, prvcursorIndex)
				drawFilename(col.mid, selectedFile, true)
				drawPreview(false)
			end
		elseif code == keyboard.keys.enter then
			if fs.isDirectory(path) then
				event.push("key_down", term.keyboard(), string.byte("l"))
			elseif extension(selectedFile) == "lua" then
				frameStash()
				shell.execute(path)
				print("\npress any key to continue")
				local id = event.pull("key_down")
				frameRestore()
			else
				event.push("key_down", term.keyboard(), string.byte("e"))
			end
		elseif c == "a" then
			if extension(selectedFile) == "lua" then
				local args = ""
				if c == 'a' then
					local prompt = string.format('run "%s" with arguments> ', selectedFile)
					term.setCursor(1,h-2)
					term.write(prompt)
					args = term.read({dobreak = false})
				end
				term.clear()
				shell.execute(path.." "..args)
				print("\npress any key to continue")
				local id = event.pull("key_down")
				refresh()
			end
		elseif c == "/" then
			if cwd ~= "/home" then
				shell.setWorkingDirectory("/home")
				refresh()
			end
		elseif c == "e" then
			frameStash()
			shell.execute("edit "..path)
			frameRestore()
			drawPreview(true)
		elseif code == keyboard.keys.delete then
			local warning
			if fs.isDirectory(path) then
				warning = "recursively delete directory!?"
			else
				warning = "delete"
			end
			if confirmation(string.format('%s "%s" ? ', warning, selectedFile)) then
				shell.execute("rm -r "..path)
				table.remove(col.mid.rows, cursorIndex)
				if #col.mid.rows == 0 then
					moveLeft()
					redraw()
					goto continue
				end
				selectedFile = col.mid.rows[cursorIndex]
				if cursorIndex == #col.mid.rows then
					-- user just removed the last item in the list
					drawFilenameIndexed(col.mid, cursorIndex, true)
				elseif #col.mid.rows < bottom-top-1 then
					-- shift all the filenames up to overwrite the deleted file's slot
					gpu.copy(col.mid.x, top+cursorIndex+1, col.mid.x+col.mid.iw, #col.mid.rows - cursorIndex+2, 0,-1)
					drawFilenameIndexed(col.mid, cursorIndex, true)
				else
					redraw()
				end
				drawPreview(true)
			end
			setInfoText("")
		elseif c == "m" then
			local prompt = "make file> "
			term.setCursor(1,h-1)
			term.write(prompt)
			local fname = term.read({dobreak = false})
			-- make directories to contain the new file, or simply make a new file in current directory
			local filepath = cwd.."/"..fname
			if fname:find("/") then
				local ok, err = shell.execute(string.format("mkdir %s", fs.path(filepath)))
				if not ok then setInfoText(err) end
			end
			local ok, err = shell.execute(string.format("touch %s", filepath))
			if not ok then setInfoText(err) else refresh() end
		elseif c == "r" then
			local prompt = string.format('rename "%s" to> ', selectedFile)
			term.setCursor(1,h-2)
			term.write(prompt)
			local fname = io.read()
			if not fname then
				setInfoText("cancelled shell command")
				goto continue
			end
			if fname:find("/$") then fname = string.sub(fname, 1,-2) end
			if confirmation(string.format('rename "%s" to "%s"?', selectedFile, fname)) then
				if path:find("/$") then
					path = string.sub(path, 1, -2)
				end
				local command = "mv "..path.." "..cwd.."/"..fname
				logvar("rename", command)
				local ok, err = shell.execute(command)
				if not ok then setInfoText(err) else
					if selectedFile:find("/$") and not fname:find("/$") then
						fname = fname.."/"
					end
					col.mid.rows[cursorIndex] = fname
					drawFilenameIndexed(col.mid, cursorIndex, true)
					setInfoText("done renaming")
					--setInfoText(string.format('renamed "%s" to "%s"', selectedFile, fname))
				end
			end
		elseif c == "s" then
			local prompt = string.format('%s # ', shell.getWorkingDirectory())
			term.setCursor(1,h-2)
			term.write(prompt)
			local command = term.read({[1]=selectedFile})
			if command == false then
				setInfoText("cancelled shell command")
				goto continue
			end
			-- I want to stash and restore the frame, but the arbitrary user
			-- shell command could have done anything
			frameStash()
			shell.execute(command)
			print("\npress any key to continue")
			local id = event.pull("key_down")
			refresh()
		elseif c == "g" then
			local prompt = "goto> "
			term.setCursor(1,h-2)
			term.write(prompt)
			local search = io.read()
			if not search then
				setInfoText("cancelled goto")
				goto continue
			end
			for i,f in ipairs(col.mid.rows) do
				if f:find(search) then
					local prvcursorIndex = cursorIndex
					cursorIndex = i
					selectedFile = f
					if cursorIndex >= bottom-2 then
						col.mid.scrollY = cursorIndex - bottom + 3
						redraw()
					elseif cursorIndex < col.mid.scrollY then
						col.mid.scrollY = cursorIndex - 1
						redraw()
					else
						drawFilenameIndexed(col.mid, prvcursorIndex)
						drawFilename(col.mid, selectedFile, true)
						drawPreview(false)
					end
					goto continue
				end
			end
			setInfoText(string.format('could not find file containing "%s"', search))
		elseif c == "y" then
			setInfoText(string.format('copied path of "%s"', selectedFile))
			clipboardBuffer = shell.getWorkingDirectory().."/"..selectedFile
		elseif c == "p" then
			if clipboardBuffer ~= "" then
				local clipboardName =  fs.name(clipboardBuffer)
				local prompt = string.format('paste "%s" to> ', clipboardName)
				term.setCursor(1,h-2)
				term.write(prompt)
				local fname = term.read({[1]=clipboardName})
				if fname == false then
					-- user ctrl-c cancelled
					setInfoText("cancelled paste")
					goto continue
				end
				if col.mid.rows[fname] == nil or confirmation(string.format('file "%s" already exists; overwrite?', fname)) then
					local command = "cp -r "..clipboardBuffer.." "..cwd.."/"..fname
					logvar("copy/paste", command)
					local ok, err = shell.execute(command)
					if not ok then setInfoText(err) else
						refresh()
					end
				end
			end
		end
	end
end