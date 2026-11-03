# NetworkToggle

Drive the app with `nettoggle` (the app binary; `nettoggle help`). See `.claude/skills/nettoggle/SKILL.md`. Commands live in
`Sources/NetworkToggle/Agent/AgentCommands.swift`; test them on a Debug build with `APP_STORE=/tmp/<name>`, which starts a
test copy on its own settings that reads the network but never talks to the helper (Release builds ignore it). Never run a
command with `--yes` in tests: it changes the real network.
