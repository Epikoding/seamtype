# A window with one text box for the typing test, writing the box's text to the file it's given
# whenever it changes. `wpf`: a WPF TextBox, a TSF text store of its own. `winforms`: a WinForms
# TextBox, the Edit control, which reaches text services through IMM32's compatibility layer
# (CUAS), as Notepad's does on Windows 10.
#   powershell -STA -File windows/scripts/field.ps1 wpf|winforms <file>
param([string]$Kind, [string]$Out)
if ($Kind -eq "winforms") {
    Add-Type -AssemblyName System.Windows.Forms
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Araso field"
    $form.Width = 500
    $form.Height = 120
    $box = New-Object System.Windows.Forms.TextBox
    $box.Dock = "Fill"
    $box.Font = New-Object System.Drawing.Font("Segoe UI", 14)
    $form.Controls.Add($box)
    $box.Add_TextChanged({ [IO.File]::WriteAllText($Out, $box.Text, [Text.Encoding]::UTF8) })
    $form.Add_Shown({ $form.TopMost = $true; $form.Activate(); $box.Focus() | Out-Null; $form.TopMost = $false })
    [System.Windows.Forms.Application]::Run($form)
    return
}
Add-Type -AssemblyName PresentationFramework
$window = New-Object System.Windows.Window
$window.Title = "Araso field"
$window.Width = 500
$window.Height = 120
$box = New-Object System.Windows.Controls.TextBox
$box.FontSize = 20
$window.Content = $box
$box.Add_TextChanged({ [IO.File]::WriteAllText($Out, $box.Text, [Text.Encoding]::UTF8) })
# In front by itself: the typing test's window may not be allowed to bring it there.
$window.Add_ContentRendered({ $window.Topmost = $true; $window.Activate() | Out-Null; $box.Focus() | Out-Null; $window.Topmost = $false })
$window.ShowDialog() | Out-Null
