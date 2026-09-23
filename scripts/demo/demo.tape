Output docs/demo.gif

Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 720
Set TypingSpeed 45ms
Set PlaybackSpeed 1
Set Framerate 30

Type "nvim --clean -u scripts/demo/init.lua scripts/demo/fixtures/example.lua"
Enter
Sleep 2s

# Open Psst beside the function and ask a contextual question.
Type ",p"
Sleep 1s
Type "iWhy does this return the smallest missing positive integer?"
Sleep 500ms
Type "ESC"
Enter
Sleep 4s

Type "q"
Sleep 1s
Type ":qa!"
Enter
Sleep 1s
