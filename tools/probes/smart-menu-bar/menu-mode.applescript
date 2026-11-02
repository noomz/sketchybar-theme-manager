on run argv
  tell application "System Events"
    set elems to entire contents of window 1 of process "System Settings"
    set popupCtl to missing value
    repeat with elemRef in elems
      set el to contents of elemRef
      if role of el is "AXPopUpButton" then
        if name of el is "Automatically hide and show the menu bar" then
          set popupCtl to el
          exit repeat
        end if
      end if
    end repeat
    if popupCtl is missing value then error "Menu-bar mode control not found"
    if (count of argv) > 0 then
      click popupCtl
      click menu item (item 1 of argv) of menu 1 of popupCtl
    end if
    return value of popupCtl
  end tell
end run
