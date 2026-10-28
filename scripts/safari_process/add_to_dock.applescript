-- Creates a Safari web app from Safari's front tab: File > Add to Dock…, name, Return.
-- osascript add_to_dock.applescript <name>
-- Needs Accessibility for the calling process (System Events) and Apple Events to Safari and
-- System Events; GitHub's macOS runner images grant both to osascript.
on run argv
	set appName to item 1 of argv
	tell application "Safari" to activate
	delay 1
	tell application "System Events"
		tell process "Safari"
			set frontmost to true
			set fileMenu to menu 1 of menu bar item 3 of menu bar 1
			set fileItems to name of every menu item of fileMenu
			set target to missing value
			repeat with candidate in menu items of fileMenu
				try
					if (name of candidate as text) starts with "Add to Dock" then set target to candidate
				end try
			end repeat
			if target is missing value then error "no 'Add to Dock' item in the File menu: " & (fileItems as text)
			if not (enabled of target) then error "'Add to Dock' is disabled"
			click target
			delay 2
			-- The sheet opens with the name field focused and selected; Return presses Add.
			keystroke "a" using command down
			keystroke appName
			delay 0.5
			key code 36
		end tell
	end tell
	return "clicked Add to Dock for " & appName
end run
