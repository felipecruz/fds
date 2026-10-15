# The terminal demo at the top of the README: docs/demo.gif.
# Record it with docs/demo.sh (needs vhs: https://github.com/charmbracelet/vhs).
Output docs/demo.gif

Set Shell bash
Set FontSize 15
Set Width 1100
Set Height 560
Set Padding 18
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms

Hide
Type "export PATH=$PWD/zig-out/release:$PATH PS1='$ ' TIMEFORMAT='(%Rs)'; cd fixtures/logs; clear" Enter
Show

Type "ls -sh logs.arrow logs.parquet   # 20 million rows of logs" Enter
Sleep 1.5s

Type "time fds --content -m 4 logs.parquet host-4242.example" Enter
Sleep 3s

Type "time fds -i -w --count logs.arrow timeout" Enter
Sleep 3s

Type "time fds -E --content -m 3 logs.arrow '^/api/v[0-9]+/checkout/\d+$'" Enter
Sleep 3s

Type "wc -l < terms.txt; time fds --count -f terms.txt logs.arrow" Enter
Sleep 3.5s

Type "fds help" Enter
Sleep 4s
