# A WPF window with one TextBox (a TSF text store of its own, unlike Notepad's Edit control, which
# reaches text services through IMM32's compatibility layer) for the typing test. Writes the box's
# text to the file it's given whenever it changes.
#   powershell -STA -File windows/scripts/wpf-field.ps1 <file>
param([string]$Out)
Add-Type -AssemblyName PresentationFramework
$window = New-Object System.Windows.Window
$window.Title = "Araso WPF field"
$window.Width = 500
$window.Height = 120
$box = New-Object System.Windows.Controls.TextBox
$box.FontSize = 20
$window.Content = $box
$box.Add_TextChanged({ [IO.File]::WriteAllText($Out, $box.Text, [Text.Encoding]::UTF8) })
$window.Add_ContentRendered({ $box.Focus() | Out-Null })
$window.ShowDialog() | Out-Null
