#requires -Version 5.1
<#
    Disk Detective
    A small Windows storage cleaner with a space map.

    - Space map: choose a drive, scan it, see what uses the space, open folders.
    - Clean up: find caches and leftovers, read what each one is, remove with
      approval into Disk Detective's own Trash (never the Recycle Bin).
    - What I did: put things back, undo a move, repair a broken shortcut.

    Run it with "Disk Detective.bat". No installation, no server, no internet.
#>
param([switch]$UiSmoke)

if ($UiSmoke) { $env:DISKDETECTIVE_SMOKE = "1" }

if (-not $script:DDToolsLoaded) { . (Join-Path $PSScriptRoot "DiskDetective.Tools.ps1") }
if (-not $script:DDPeopleLoaded) { . (Join-Path $PSScriptRoot "DiskDetective.Data.ps1") }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Only one copy may run at a time. Two windows could move or delete the same
# folder at once, and each would think it was alone.
$script:SingleInstanceMutex = New-Object System.Threading.Mutex($false, "Local\DiskDetective.SingleInstance")
$script:SingleInstanceOwned = $false
try { $script:SingleInstanceOwned = $script:SingleInstanceMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $script:SingleInstanceOwned = $true }
if (-not $script:SingleInstanceOwned) {
    [void][System.Windows.Forms.MessageBox]::Show("Disk Detective is already open. Use the window that is already running.", "Disk Detective", "OK", "Information")
    exit 0
}

function Release-SingleInstance {
    if ($script:SingleInstanceOwned) {
        try { [void]$script:SingleInstanceMutex.ReleaseMutex() } catch { }
        $script:SingleInstanceOwned = $false
    }
}

$script:Settings = Get-Settings
$baseSize = 11.5
if ($script:Settings.LargeText) { $baseSize = 14.5 }

$fontBase = New-Object System.Drawing.Font("Segoe UI", [float]$baseSize)
$fontSmall = New-Object System.Drawing.Font("Segoe UI", [float]($baseSize - 1))
$fontText = New-Object System.Drawing.Font("Segoe UI", [float]$baseSize)
$fontTitle = New-Object System.Drawing.Font("Segoe UI", [float]($baseSize + 10), [System.Drawing.FontStyle]::Bold)
$fontHead = New-Object System.Drawing.Font("Segoe UI", [float]($baseSize + 5), [System.Drawing.FontStyle]::Bold)
$fontButton = New-Object System.Drawing.Font("Segoe UI", [float]$baseSize, [System.Drawing.FontStyle]::Bold)
$script:FontMap = $fontSmall

$script:Items = @()
$script:MapNodes = @()
$script:MapPath = ""
$script:MapHistory = New-Object System.Collections.Generic.Stack[string]
$script:MapRects = New-Object System.Collections.ArrayList
$script:DriveRoots = @()
$script:DeepMode = $false
$script:CancelRequested = $false
$script:Scan = $null
$script:DeepFiles = @()
$script:RiskColors = @{
    "safe"      = [System.Drawing.Color]::FromArgb(234, 249, 241)
    "low"       = [System.Drawing.Color]::FromArgb(234, 243, 255)
    "caution"   = [System.Drawing.Color]::FromArgb(255, 246, 224)
    "protected" = [System.Drawing.Color]::FromArgb(253, 234, 237)
}

# ---------------------------------------------------------------- the window

$form = New-Object System.Windows.Forms.Form
$form.Text = "Disk Detective"
$form.Size = New-Object System.Drawing.Size(1220, 840)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 600)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 249, 252)
$form.Font = $fontBase
# The layout is fixed in pixels; Windows scales the whole window on a high-DPI
# screen. Automatic scaling here would double-scale and drift the layout.
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.KeyPreview = $true
$form.AccessibleName = "Disk Detective"

$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Fill"
$header.BackColor = [System.Drawing.Color]::White
$header.Margin = New-Object System.Windows.Forms.Padding(0)

$brand = New-Object System.Windows.Forms.Label
$brand.Text = "Disk Detective"
$brand.Font = $fontTitle
$brand.ForeColor = [System.Drawing.Color]::FromArgb(16, 24, 34)
$brand.AutoSize = $true
$brand.Location = New-Object System.Drawing.Point(24, 10)
$header.Controls.Add($brand)

$tagline = New-Object System.Windows.Forms.Label
$tagline.Text = "See what uses your space, understand every folder, and move big ones to another drive."
$tagline.Font = $fontBase
$tagline.ForeColor = [System.Drawing.Color]::FromArgb(90, 102, 118)
$tagline.AutoSize = $true
$tagline.Location = New-Object System.Drawing.Point(26, 58)
$header.Controls.Add($tagline)

$chkLarge = New-Object System.Windows.Forms.CheckBox
$chkLarge.Text = "Larger text"
$chkLarge.Font = $fontBase
$chkLarge.AutoSize = $true
$chkLarge.Anchor = "Top,Right"
$chkLarge.Location = New-Object System.Drawing.Point(1090, 30)
$chkLarge.Checked = $script:Settings.LargeText
$chkLarge.AccessibleName = "Use larger text"
$header.Controls.Add($chkLarge)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "Fill"
$tabs.Font = $fontBase
$tabs.Margin = New-Object System.Windows.Forms.Padding(12, 8, 12, 4)

$mapPage = New-Object System.Windows.Forms.TabPage
$mapPage.Text = "  Space map  "
$mapPage.BackColor = [System.Drawing.Color]::FromArgb(246, 249, 252)
$tabs.TabPages.Add($mapPage) | Out-Null

$cleanPage = New-Object System.Windows.Forms.TabPage
$cleanPage.Text = "  Clean up  "
$cleanPage.BackColor = [System.Drawing.Color]::FromArgb(246, 249, 252)
$tabs.TabPages.Add($cleanPage) | Out-Null

$historyPage = New-Object System.Windows.Forms.TabPage
$historyPage.Text = "  What I did  "
$historyPage.BackColor = [System.Drawing.Color]::FromArgb(246, 249, 252)
$tabs.TabPages.Add($historyPage) | Out-Null

# ---------------------------------------------------------------- space map

$mapLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mapLayout.Dock = "Fill"
$mapLayout.ColumnCount = 1
$mapLayout.RowCount = 4
[void]$mapLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [float]104)))
[void]$mapLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, [float]45)))
[void]$mapLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, [float]55)))
[void]$mapLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [float]64)))
$mapPage.Controls.Add($mapLayout)

$mapTop = New-Object System.Windows.Forms.Panel
$mapTop.Dock = "Fill"
$mapTop.Margin = New-Object System.Windows.Forms.Padding(0)
$mapLayout.Controls.Add($mapTop, 0, 0)

$lblDrive = New-Object System.Windows.Forms.Label
$lblDrive.Text = "Drive:"
$lblDrive.Font = $fontText
$lblDrive.AutoSize = $true
$lblDrive.Location = New-Object System.Drawing.Point(16, 20)
$mapTop.Controls.Add($lblDrive)

$cmbDrive = New-Object System.Windows.Forms.ComboBox
$cmbDrive.DropDownStyle = "DropDownList"
$cmbDrive.Font = $fontText
$cmbDrive.Size = New-Object System.Drawing.Size(300, 30)
$cmbDrive.Location = New-Object System.Drawing.Point(74, 16)
$cmbDrive.AccessibleName = "Drive to scan"
$mapTop.Controls.Add($cmbDrive)

$btnScanDrive = New-Object System.Windows.Forms.Button
$btnScanDrive.Text = "Scan drive"
$btnScanDrive.Font = $fontButton
$btnScanDrive.BackColor = [System.Drawing.Color]::FromArgb(34, 184, 132)
$btnScanDrive.ForeColor = [System.Drawing.Color]::White
$btnScanDrive.FlatStyle = "Flat"
$btnScanDrive.FlatAppearance.BorderSize = 0
$btnScanDrive.Size = New-Object System.Drawing.Size(140, 44)
$btnScanDrive.Location = New-Object System.Drawing.Point(386, 12)
$btnScanDrive.Cursor = [System.Windows.Forms.Cursors]::Hand
$mapTop.Controls.Add($btnScanDrive)

$btnScanDeep = New-Object System.Windows.Forms.Button
$btnScanDeep.Text = "Whole drive scan"
$btnScanDeep.Font = $fontText
$btnScanDeep.Size = New-Object System.Drawing.Size(180, 44)
$btnScanDeep.Location = New-Object System.Drawing.Point(534, 12)
$btnScanDeep.FlatStyle = "Flat"
$btnScanDeep.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnScanDeep.Cursor = [System.Windows.Forms.Cursors]::Hand
$mapTop.Controls.Add($btnScanDeep)

$btnUp = New-Object System.Windows.Forms.Button
$btnUp.Text = "Up one level"
$btnUp.Font = $fontText
$btnUp.Size = New-Object System.Drawing.Size(130, 44)
$btnUp.Location = New-Object System.Drawing.Point(752, 12)
$btnUp.FlatStyle = "Flat"
$btnUp.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnUp.Enabled = $false
$btnUp.Cursor = [System.Windows.Forms.Cursors]::Hand
$mapTop.Controls.Add($btnUp)

$lblCrumb = New-Object System.Windows.Forms.Label
        $lblCrumb.Text = "Choose a drive, then press Scan drive - or Whole drive scan to find the biggest folders anywhere."
$lblCrumb.Font = $fontSmall
$lblCrumb.ForeColor = [System.Drawing.Color]::FromArgb(100, 112, 128)
$lblCrumb.AutoSize = $false
$lblCrumb.Size = New-Object System.Drawing.Size(1050, 26)
$lblCrumb.Location = New-Object System.Drawing.Point(18, 68)
$mapTop.Controls.Add($lblCrumb)
$mapTop.Add_Resize({ if ($lblCrumb) { $lblCrumb.Width = [math]::Max(300, $mapTop.ClientSize.Width - 36) } })

$mapPanel = New-Object System.Windows.Forms.Panel
$mapPanel.Dock = "Fill"
$mapPanel.BackColor = [System.Drawing.Color]::White
$mapPanel.BorderStyle = "FixedSingle"
$mapPanel.Margin = New-Object System.Windows.Forms.Padding(12, 4, 12, 6)
$mapPanel.AccessibleName = "Space map of folders as blocks"
$mapLayout.Controls.Add($mapPanel, 0, 1)

$folders = New-Object System.Windows.Forms.ListView
$folders.Dock = "Fill"
$folders.View = "Details"
$folders.FullRowSelect = $true
$folders.HideSelection = $false
$folders.MultiSelect = $true
$folders.GridLines = $false
$folders.Font = $fontText
$folders.BorderStyle = "None"
$folders.BackColor = [System.Drawing.Color]::White
$folders.Margin = New-Object System.Windows.Forms.Padding(12, 0, 12, 6)
$folderImages = New-Object System.Windows.Forms.ImageList
$folderImages.ImageSize = New-Object System.Drawing.Size(1, 32)
$folders.SmallImageList = $folderImages
[void]$folders.Columns.Add("Folder", 380)
[void]$folders.Columns.Add("Size", 120, [System.Windows.Forms.HorizontalAlignment]::Right)
[void]$folders.Columns.Add("Files", 100, [System.Windows.Forms.HorizontalAlignment]::Right)
[void]$folders.Columns.Add("Last used", 160)
[void]$folders.Columns.Add("Type", 220)
$folders.ShowItemToolTips = $true
$mapLayout.Controls.Add($folders, 0, 2)

$mapBottom = New-Object System.Windows.Forms.Panel
$mapBottom.Dock = "Fill"
$mapBottom.Margin = New-Object System.Windows.Forms.Padding(0)
$mapLayout.Controls.Add($mapBottom, 0, 3)

$btnMoveFolder = New-Object System.Windows.Forms.Button
$btnMoveFolder.Text = "Move selected folder(s)..."
$btnMoveFolder.Font = $fontButton
$btnMoveFolder.Size = New-Object System.Drawing.Size(300, 44)
$btnMoveFolder.Location = New-Object System.Drawing.Point(16, 8)
$btnMoveFolder.FlatStyle = "Flat"
$btnMoveFolder.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnMoveFolder.Enabled = $false
$btnMoveFolder.Cursor = [System.Windows.Forms.Cursors]::Hand
$mapBottom.Controls.Add($btnMoveFolder)

$btnExplain = New-Object System.Windows.Forms.Button
$btnExplain.Text = "What is this folder?"
$btnExplain.Font = $fontText
$btnExplain.Size = New-Object System.Drawing.Size(220, 44)
$btnExplain.Location = New-Object System.Drawing.Point(424, 8)
$btnExplain.FlatStyle = "Flat"
$btnExplain.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnExplain.Enabled = $false
$btnExplain.Cursor = [System.Windows.Forms.Cursors]::Hand
$mapBottom.Controls.Add($btnExplain)

# ---------------------------------------------------------------- clean up

$cleanLayout = New-Object System.Windows.Forms.TableLayoutPanel
$cleanLayout.Dock = "Fill"
$cleanLayout.ColumnCount = 1
$cleanLayout.RowCount = 4
[void]$cleanLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [float]66)))
[void]$cleanLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [float]0)))
[void]$cleanLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [float]0)))
[void]$cleanLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, [float]100)))
$cleanPage.Controls.Add($cleanLayout)
$script:CleanLayout = $cleanLayout

$cleanTop = New-Object System.Windows.Forms.Panel
$cleanTop.Dock = "Fill"
$cleanTop.Margin = New-Object System.Windows.Forms.Padding(0)
$cleanLayout.Controls.Add($cleanTop, 0, 0)

$btnScanCaches = New-Object System.Windows.Forms.Button
$btnScanCaches.Text = "Scan my PC"
$btnScanCaches.Font = $fontButton
$btnScanCaches.BackColor = [System.Drawing.Color]::FromArgb(34, 184, 132)
$btnScanCaches.ForeColor = [System.Drawing.Color]::White
$btnScanCaches.FlatStyle = "Flat"
$btnScanCaches.FlatAppearance.BorderSize = 0
$btnScanCaches.Size = New-Object System.Drawing.Size(200, 44)
$btnScanCaches.Location = New-Object System.Drawing.Point(14, 10)
$btnScanCaches.Cursor = [System.Windows.Forms.Cursors]::Hand
$cleanTop.Controls.Add($btnScanCaches)

$steps = New-Object System.Windows.Forms.Label
$steps.Text = "1. Scan      2. Read      3. Approve"
$steps.Font = $fontText
$steps.ForeColor = [System.Drawing.Color]::FromArgb(52, 66, 84)
$steps.AutoSize = $true
$steps.Location = New-Object System.Drawing.Point(230, 22)
$cleanTop.Controls.Add($steps)

$btnDuplicates = New-Object System.Windows.Forms.Button
$btnDuplicates.Text = "Duplicate files..."
$btnDuplicates.Font = $fontText
$btnDuplicates.Size = New-Object System.Drawing.Size(170, 38)
$btnDuplicates.Anchor = "Top,Right"
$btnDuplicates.Location = New-Object System.Drawing.Point(806, 14)
$btnDuplicates.FlatStyle = "Flat"
$btnDuplicates.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnDuplicates.Cursor = [System.Windows.Forms.Cursors]::Hand
$cleanTop.Controls.Add($btnDuplicates)

$btnReserves = New-Object System.Windows.Forms.Button
$btnReserves.Text = "Windows reserves..."
$btnReserves.Font = $fontText
$btnReserves.Size = New-Object System.Drawing.Size(180, 38)
$btnReserves.Anchor = "Top,Right"
$btnReserves.Location = New-Object System.Drawing.Point(984, 14)
$btnReserves.FlatStyle = "Flat"
$btnReserves.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnReserves.Cursor = [System.Windows.Forms.Cursors]::Hand
$cleanTop.Controls.Add($btnReserves)

$banner = New-Object System.Windows.Forms.Panel
$banner.Dock = "Fill"
$banner.BackColor = [System.Drawing.Color]::FromArgb(232, 248, 241)
$banner.Visible = $false
$banner.Margin = New-Object System.Windows.Forms.Padding(0)
$cleanLayout.Controls.Add($banner, 0, 1)

$lblHeadline = New-Object System.Windows.Forms.Label
$lblHeadline.Text = "Scan finished"
$lblHeadline.Font = $fontHead
$lblHeadline.ForeColor = [System.Drawing.Color]::FromArgb(12, 92, 64)
$lblHeadline.AutoSize = $true
$lblHeadline.Location = New-Object System.Drawing.Point(16, 8)
$banner.Controls.Add($lblHeadline)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = ""
$lblSub.Font = $fontText
$lblSub.AutoSize = $false
$lblSub.Size = New-Object System.Drawing.Size(720, 92)
$lblSub.Location = New-Object System.Drawing.Point(18, 46)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(52, 80, 68)
$banner.Controls.Add($lblSub)

$btnClean = New-Object System.Windows.Forms.Button
$btnClean.Text = "Clean up safe items"
$btnClean.Font = $fontButton
$btnClean.BackColor = [System.Drawing.Color]::FromArgb(34, 184, 132)
$btnClean.ForeColor = [System.Drawing.Color]::White
$btnClean.FlatStyle = "Flat"
$btnClean.FlatAppearance.BorderSize = 0
$btnClean.Size = New-Object System.Drawing.Size(330, 58)
$btnClean.Location = New-Object System.Drawing.Point(844, 44)
$btnClean.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnClean.Enabled = $false
$banner.Controls.Add($btnClean)

# The banner only appears after a scan, so its children are positioned from its
# real width at that moment (anchoring would use the hidden width).
$banner.Add_Resize({
    if ($btnClean) { $btnClean.Left = [math]::Max(20, $banner.ClientSize.Width - $btnClean.Width - 30) }
    if ($lblSub) { $lblSub.Width = [math]::Max(280, $btnClean.Left - 36) }
})

$cleanActions = New-Object System.Windows.Forms.Panel
$cleanActions.Dock = "Fill"
$cleanActions.BackColor = [System.Drawing.Color]::White
$cleanActions.Visible = $false
$cleanActions.Margin = New-Object System.Windows.Forms.Padding(0)
$cleanLayout.Controls.Add($cleanActions, 0, 2)

$lblShow = New-Object System.Windows.Forms.Label
$lblShow.Text = "Show:"
$lblShow.Font = $fontText
$lblShow.AutoSize = $true
$lblShow.Location = New-Object System.Drawing.Point(16, 16)
$cleanActions.Controls.Add($lblShow)

$cmbFilter = New-Object System.Windows.Forms.ComboBox
$cmbFilter.DropDownStyle = "DropDownList"
$cmbFilter.Font = $fontText
$cmbFilter.Size = New-Object System.Drawing.Size(190, 30)
$cmbFilter.Location = New-Object System.Drawing.Point(66, 12)
[void]$cmbFilter.Items.AddRange(@("Everything", "Safe to delete", "Low risk", "Ask before deleting", "Protected"))
$cmbFilter.SelectedIndex = 0
$cleanActions.Controls.Add($cmbFilter)

$btnDetails = New-Object System.Windows.Forms.Button
$btnDetails.Text = "What is this?"
$btnDetails.Font = $fontText
$btnDetails.Size = New-Object System.Drawing.Size(130, 38)
$btnDetails.Location = New-Object System.Drawing.Point(268, 9)
$btnDetails.FlatStyle = "Flat"
$btnDetails.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnDetails.Cursor = [System.Windows.Forms.Cursors]::Hand
$cleanActions.Controls.Add($btnDetails)

$btnMoveCache = New-Object System.Windows.Forms.Button
$btnMoveCache.Text = "Move this folder..."
$btnMoveCache.Font = $fontText
$btnMoveCache.Size = New-Object System.Drawing.Size(158, 38)
$btnMoveCache.Location = New-Object System.Drawing.Point(406, 9)
$btnMoveCache.FlatStyle = "Flat"
$btnMoveCache.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnMoveCache.Cursor = [System.Windows.Forms.Cursors]::Hand
$cleanActions.Controls.Add($btnMoveCache)

$btnIgnore = New-Object System.Windows.Forms.Button
$btnIgnore.Text = "Leave this alone"
$btnIgnore.Font = $fontText
$btnIgnore.Size = New-Object System.Drawing.Size(150, 38)
$btnIgnore.Location = New-Object System.Drawing.Point(572, 9)
$btnIgnore.FlatStyle = "Flat"
$btnIgnore.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnIgnore.Cursor = [System.Windows.Forms.Cursors]::Hand
$cleanActions.Controls.Add($btnIgnore)

$btnDeleteChecked = New-Object System.Windows.Forms.Button
$btnDeleteChecked.Text = "Delete ticked items"
$btnDeleteChecked.Font = $fontText
$btnDeleteChecked.Size = New-Object System.Drawing.Size(220, 38)
$btnDeleteChecked.Location = New-Object System.Drawing.Point(730, 9)
$btnDeleteChecked.FlatStyle = "Flat"
$btnDeleteChecked.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnDeleteChecked.Enabled = $false
$btnDeleteChecked.Cursor = [System.Windows.Forms.Cursors]::Hand
$cleanActions.Controls.Add($btnDeleteChecked)

$cacheList = New-Object System.Windows.Forms.ListView
$cacheList.Dock = "Fill"
$cacheList.View = "Details"
$cacheList.CheckBoxes = $true
$cacheList.FullRowSelect = $true
$cacheList.HideSelection = $false
$cacheList.MultiSelect = $true
$cacheList.GridLines = $false
$cacheList.Font = $fontText
$cacheList.BorderStyle = "None"
$cacheList.BackColor = [System.Drawing.Color]::White
$cacheList.Margin = New-Object System.Windows.Forms.Padding(12, 0, 12, 8)
$cacheImages = New-Object System.Windows.Forms.ImageList
$cacheImages.ImageSize = New-Object System.Drawing.Size(1, 32)
$cacheList.SmallImageList = $cacheImages
[void]$cacheList.Columns.Add("Item", 280)
[void]$cacheList.Columns.Add("What it is", 330)
[void]$cacheList.Columns.Add("Size", 110, [System.Windows.Forms.HorizontalAlignment]::Right)
[void]$cacheList.Columns.Add("Last used", 150)
[void]$cacheList.Columns.Add("Risk", 180)
$cacheList.ShowItemToolTips = $true
$cleanLayout.Controls.Add($cacheList, 0, 3)

# ---------------------------------------------------------------- history

$historyLayout = New-Object System.Windows.Forms.TableLayoutPanel
$historyLayout.Dock = "Fill"
$historyLayout.ColumnCount = 1
$historyLayout.RowCount = 3
[void]$historyLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [float]60)))
[void]$historyLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, [float]100)))
[void]$historyLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [float]66)))
$historyPage.Controls.Add($historyLayout)

$historyTop = New-Object System.Windows.Forms.Panel
$historyTop.Dock = "Fill"
$historyTop.Margin = New-Object System.Windows.Forms.Padding(0)
$historyLayout.Controls.Add($historyTop, 0, 0)

$lblHistory = New-Object System.Windows.Forms.Label
$lblHistory.Text = "Nothing has been changed yet."
$lblHistory.Font = $fontText
$lblHistory.ForeColor = [System.Drawing.Color]::FromArgb(52, 66, 84)
$lblHistory.AutoSize = $true
$lblHistory.Location = New-Object System.Drawing.Point(18, 18)
$historyTop.Controls.Add($lblHistory)



$historyList = New-Object System.Windows.Forms.ListView
$historyList.Dock = "Fill"
$historyList.View = "Details"
$historyList.FullRowSelect = $true
$historyList.HideSelection = $false
$historyList.MultiSelect = $false
$historyList.Font = $fontText
$historyList.BorderStyle = "None"
$historyList.BackColor = [System.Drawing.Color]::White
$historyList.Margin = New-Object System.Windows.Forms.Padding(12, 0, 12, 6)
$historyImages = New-Object System.Windows.Forms.ImageList
$historyImages.ImageSize = New-Object System.Drawing.Size(1, 32)
$historyList.SmallImageList = $historyImages
[void]$historyList.Columns.Add("What", 280)
[void]$historyList.Columns.Add("Where", 380)
[void]$historyList.Columns.Add("Size", 100, [System.Windows.Forms.HorizontalAlignment]::Right)
[void]$historyList.Columns.Add("When", 150)
[void]$historyList.Columns.Add("Status", 250)
$historyLayout.Controls.Add($historyList, 0, 1)

$historyBottom = New-Object System.Windows.Forms.Panel
$historyBottom.Dock = "Fill"
$historyBottom.Margin = New-Object System.Windows.Forms.Padding(0)
$historyLayout.Controls.Add($historyBottom, 0, 2)

$btnPutBack = New-Object System.Windows.Forms.Button
$btnPutBack.Text = "Put it back"
$btnPutBack.Font = $fontButton
$btnPutBack.Size = New-Object System.Drawing.Size(170, 44)
$btnPutBack.Location = New-Object System.Drawing.Point(16, 8)
$btnPutBack.FlatStyle = "Flat"
$btnPutBack.BackColor = [System.Drawing.Color]::FromArgb(232, 248, 241)
$btnPutBack.Enabled = $false
$btnPutBack.Cursor = [System.Windows.Forms.Cursors]::Hand
$historyBottom.Controls.Add($btnPutBack)

$btnUndo = New-Object System.Windows.Forms.Button
$btnUndo.Text = "Undo this move"
$btnUndo.Font = $fontText
$btnUndo.Size = New-Object System.Drawing.Size(180, 44)
$btnUndo.Location = New-Object System.Drawing.Point(194, 8)
$btnUndo.FlatStyle = "Flat"
$btnUndo.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnUndo.Enabled = $false
$btnUndo.Cursor = [System.Windows.Forms.Cursors]::Hand
$historyBottom.Controls.Add($btnUndo)

$btnRepair = New-Object System.Windows.Forms.Button
$btnRepair.Text = "Repair shortcut..."
$btnRepair.Font = $fontText
$btnRepair.Size = New-Object System.Drawing.Size(180, 44)
$btnRepair.Location = New-Object System.Drawing.Point(382, 8)
$btnRepair.FlatStyle = "Flat"
$btnRepair.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnRepair.Enabled = $false
$btnRepair.Cursor = [System.Windows.Forms.Cursors]::Hand
$historyBottom.Controls.Add($btnRepair)

$btnCheckLinks = New-Object System.Windows.Forms.Button
$btnCheckLinks.Text = "Check all shortcuts"
$btnCheckLinks.Font = $fontText
$btnCheckLinks.Size = New-Object System.Drawing.Size(190, 44)
$btnCheckLinks.Location = New-Object System.Drawing.Point(570, 8)
$btnCheckLinks.FlatStyle = "Flat"
$btnCheckLinks.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
$btnCheckLinks.Cursor = [System.Windows.Forms.Cursors]::Hand
$historyBottom.Controls.Add($btnCheckLinks)

$btnDeleteForever = New-Object System.Windows.Forms.Button
$btnDeleteForever.Text = "Delete for good"
$btnDeleteForever.Font = $fontText
$btnDeleteForever.Size = New-Object System.Drawing.Size(170, 44)
$btnDeleteForever.Location = New-Object System.Drawing.Point(768, 8)
$btnDeleteForever.FlatStyle = "Flat"
$btnDeleteForever.BackColor = [System.Drawing.Color]::FromArgb(255, 240, 240)
$btnDeleteForever.Enabled = $false
$btnDeleteForever.Cursor = [System.Windows.Forms.Cursors]::Hand
$historyBottom.Controls.Add($btnDeleteForever)

# --- status
$status = New-Object System.Windows.Forms.StatusStrip
$status.BackColor = [System.Drawing.Color]::White
$status.Dock = "Fill"
$status.SizingGrip = $false
$status.Margin = New-Object System.Windows.Forms.Padding(0)

$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatus.Text = "Ready."
$lblStatus.Font = $fontSmall
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(90, 102, 118)
# A fixed-width spring label: it takes the space the right-hand links leave,
# and the text is shortened to fit instead of running underneath them.
$lblStatus.AutoSize = $false
$lblStatus.Width = 500
$lblStatus.Spring = $true
$lblStatus.AutoToolTip = $true
$lblStatus.TextAlign = "MiddleLeft"
[void]$status.Items.Add($lblStatus)
$script:StatusFullText = "Ready."

$progressBar = New-Object System.Windows.Forms.ToolStripProgressBar
$progressBar.Size = New-Object System.Drawing.Size(160, 16)
$progressBar.Style = "Marquee"
$progressBar.MarqueeAnimationSpeed = 30
$progressBar.Visible = $false
[void]$status.Items.Add($progressBar)

$btnCancel = New-Object System.Windows.Forms.ToolStripButton
$btnCancel.Text = "Stop"
$btnCancel.Font = $fontSmall
$btnCancel.Visible = $false
[void]$status.Items.Add($btnCancel)

$btnAdminRestart = New-Object System.Windows.Forms.ToolStripButton
$btnAdminRestart.Text = "Restart as administrator"
$btnAdminRestart.Font = $fontSmall
$btnAdminRestart.Visible = (-not (Test-IsAdmin))
[void]$status.Items.Add($btnAdminRestart)

$btnReport = New-Object System.Windows.Forms.ToolStripButton
$btnReport.Text = "Save a report"
$btnReport.Font = $fontSmall
[void]$status.Items.Add($btnReport)

$btnIgnored = New-Object System.Windows.Forms.ToolStripButton
$btnIgnored.Text = "Ignored folders"
$btnIgnored.Font = $fontSmall
[void]$status.Items.Add($btnIgnored)

# ---------------------------------------------------------------- layout

$rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
$rootLayout.Dock = "Fill"
$rootLayout.ColumnCount = 1
$rootLayout.RowCount = 3
[void]$rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, [float]100)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [float]100)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, [float]100)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [float]30)))
[void]$rootLayout.Controls.Add($header, 0, 0)
[void]$rootLayout.Controls.Add($tabs, 0, 1)
[void]$rootLayout.Controls.Add($status, 0, 2)
$form.Controls.Add($rootLayout)

# ---------------------------------------------------------------- helpers

function Get-ShortStatusText {
    param([string]$Text, [int]$MaxWidth)
    if (-not $Text) { return "" }
    if ($MaxWidth -le 30) { return "" }
    $font = $lblStatus.Font
    if ([System.Windows.Forms.TextRenderer]::MeasureText($Text, $font).Width -le $MaxWidth) { return $Text }
    $ellipsis = [string][char]0x2026
    $low = 0
    $high = $Text.Length
    while ($low -lt $high) {
        $mid = [int](($low + $high + 1) / 2)
        $candidate = $Text.Substring(0, $mid).TrimEnd() + $ellipsis
        if ([System.Windows.Forms.TextRenderer]::MeasureText($candidate, $font).Width -le $MaxWidth) {
            $low = $mid
        } else {
            $high = $mid - 1
        }
    }
    if ($low -le 0) { return $ellipsis }
    return $Text.Substring(0, $low).TrimEnd() + $ellipsis
}

function Update-StatusLayout {
    if ($form.IsDisposed -or -not $lblStatus) { return }
    if ($lblStatus.Width -lt 40) { return }
    $shown = Get-ShortStatusText -Text $script:StatusFullText -MaxWidth ($lblStatus.Width - 12)
    if ($lblStatus.Text -ne $shown) { $lblStatus.Text = $shown }
}

function Set-StatusText {
    param([string]$Text)
    if ($form.IsDisposed) { return }
    $script:StatusFullText = [string]$Text
    $lblStatus.ToolTipText = $script:StatusFullText
    Update-StatusLayout
}

function Update-LiveStatus {
    param([string]$Text)
    if ($form.IsDisposed) { return }
    [System.Windows.Forms.Application]::DoEvents()
    Set-StatusText $Text
    [System.Windows.Forms.Application]::DoEvents()
}

$status.Add_Resize({ Update-StatusLayout })

function Set-Busy {
    param([bool]$Busy)
    if ($form.IsDisposed) { return }
    $progressBar.Visible = $Busy
    $btnCancel.Visible = $Busy
    $chkLarge.Enabled = -not $Busy
    if ($btnAdminRestart.Visible) { $btnAdminRestart.Enabled = -not $Busy }
    # Showing the bar and Stop shortens the text area; re-fit the words.
    $status.PerformLayout()
    Update-StatusLayout
    $btnScanDrive.Enabled = -not $Busy
    $btnScanDeep.Enabled = -not $Busy
    $btnScanCaches.Enabled = -not $Busy
    $btnDetails.Enabled = -not $Busy
    $btnMoveCache.Enabled = -not $Busy
    $btnIgnore.Enabled = -not $Busy
    $btnDuplicates.Enabled = -not $Busy
    $btnReserves.Enabled = -not $Busy
    $btnMoveFolder.Enabled = (-not $Busy -and $folders.SelectedItems.Count -gt 0)
    $btnExplain.Enabled = (-not $Busy -and $folders.SelectedItems.Count -gt 0)
    $btnUp.Enabled = (-not $Busy -and $script:MapHistory.Count -gt 0)
    $btnClean.Enabled = (-not $Busy -and @($script:Items | Where-Object { $_.Risk -eq "safe" }).Count -gt 0)
    $btnDeleteChecked.Enabled = (-not $Busy -and @($cacheList.CheckedItems).Count -gt 0)
    $form.Cursor = if ($Busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
}

function Update-DriveList {
    $cmbDrive.Items.Clear()
    $script:DriveRoots = @()
    foreach ($drive in (Get-FixedDrives)) {
        $script:DriveRoots += $drive
        $kind = "disk"
        if ($drive.Removable) { $kind = "USB disk" }
        [void]$cmbDrive.Items.Add("$($drive.Label)   -   $(Format-Size $drive.Free) free of $(Format-Size $drive.Total)  ($kind)")
    }
    if ($cmbDrive.Items.Count -gt 0) {
        $index = 0
        $wanted = $script:Settings.LastDrive
        for ($i = 0; $i -lt $script:DriveRoots.Count; $i++) {
            if ($wanted -and $script:DriveRoots[$i].Label -eq $wanted) { $index = $i; break }
            $systemRoot = [System.IO.Path]::GetPathRoot($env:WINDIR)
            if ($systemRoot -and $script:DriveRoots[$i].Root -eq $systemRoot) { $index = $i }
        }
        $cmbDrive.SelectedIndex = $index
    }
}

function Get-SelectedDriveRoot {
    if ($cmbDrive.SelectedIndex -lt 0 -or $cmbDrive.SelectedIndex -ge $script:DriveRoots.Count) { return $null }
    return $script:DriveRoots[$cmbDrive.SelectedIndex].Root
}

function Fill-FolderList {
    $folders.BeginUpdate()
    try {
        $folders.Items.Clear()
        foreach ($node in $script:MapNodes) {
            $label = $node.Name
            if ($script:DeepMode) { $label = $node.Path }
            $row = New-Object System.Windows.Forms.ListViewItem($label)
            [void]$row.SubItems.Add((Format-Size $node.Bytes))
            [void]$row.SubItems.Add(([int]$node.Files).ToString("N0"))
            [void]$row.SubItems.Add((Format-Age $node.LastUsed))
            if ($node.IsLink -and $node.Target) { [void]$row.SubItems.Add("shortcut -> $($node.Target)") }
            elseif ($node.IsLink) { [void]$row.SubItems.Add("shortcut") }
            else { [void]$row.SubItems.Add("folder") }
            $row.Tag = $node
            $row.ToolTipText = $node.Path
            [void]$folders.Items.Add($row)
        }

        if ($script:DeepMode) {
            foreach ($file in @($script:DeepFiles)) {
                $row = New-Object System.Windows.Forms.ListViewItem([string]$file.Path)
                [void]$row.SubItems.Add((Format-Size $file.Bytes))
                [void]$row.SubItems.Add("1")
                [void]$row.SubItems.Add((Format-Age $file.LastUsed))
                [void]$row.SubItems.Add("file (10 MB or more)")
                $row.Tag = [pscustomobject]@{
                    Path = $file.Path; Name = $file.Name; Bytes = [int64]$file.Bytes; Files = 1
                    LastUsed = $file.LastUsed; IsLink = $false; IsFile = $true; Target = $null
                }
                [void]$folders.Items.Add($row)
            }
        }
    } finally {
        $folders.EndUpdate()
    }
}

function Update-Crumb {
    if ($script:DeepMode -and $script:Scan) {
        $scan = $script:Scan
        $lblCrumb.Text = "Biggest folders anywhere on $($scan.Root)   -   $(Format-Size $scan.FolderBytes) in $($scan.FolderFiles) files, $($scan.TotalFolders) folders, took $($scan.Seconds)s."
        return
    }
    if ($script:MapPath) {
        $free = ""
        try {
            $space = Get-FreeSpace $script:MapPath
            if ($space.Total -gt 0) { $free = "   -   $(Format-Size $space.Free) free of $(Format-Size $space.Total)" }
        } catch { }
        $lblCrumb.Text = "$($script:MapPath)$free"
    }
}

function Show-MapFolder {
    param([string]$Path, [switch]$Remember)

    if ($Remember -and $script:MapPath) { $script:MapHistory.Push($script:MapPath) }

    Set-Busy $true
    try {
        $script:DeepMode = $false
        $script:DeepFiles = @()
        $script:Scan = $null
        $script:MapPath = $Path
        Update-Crumb
        Update-LiveStatus "Reading $Path ..."
        $script:MapNodes = Get-FolderChildren -Path $Path -Progress { param($text) Update-LiveStatus $text }
        if ($form.IsDisposed) { return }
        $script:MapRects.Clear()
        Fill-FolderList
        $mapPanel.Invalidate()
        $lblStatus.Text = "$Path - $($script:MapNodes.Count) folders. Double-click a block to open it."
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("Could not read $Path.`n`n$($_.Exception.Message)", "Disk Detective", "OK", "Warning")
        $lblStatus.Text = "Stopped."
    } finally {
        Set-Busy $false
    }
}

function Select-MapNode {
    param($Node)
    foreach ($row in $folders.Items) {
        if ($row.Tag -and $row.Tag.Path -eq $Node.Path) {
            $row.Selected = $true
            $row.EnsureVisible()
            break
        }
    }
}

# ---------------------------------------------------------------- treemap

function Get-NodeColor {
    param([int]$Index)
    $palette = @(
        [System.Drawing.Color]::FromArgb(122, 178, 216),
        [System.Drawing.Color]::FromArgb(136, 196, 164),
        [System.Drawing.Color]::FromArgb(226, 186, 122),
        [System.Drawing.Color]::FromArgb(176, 158, 208),
        [System.Drawing.Color]::FromArgb(134, 162, 206),
        [System.Drawing.Color]::FromArgb(214, 150, 150),
        [System.Drawing.Color]::FromArgb(158, 194, 146),
        [System.Drawing.Color]::FromArgb(198, 172, 132)
    )
    return $palette[$Index % $palette.Count]
}

function Draw-Treemap {
    param($Graphics, [System.Drawing.Rectangle]$Bounds)

    $Graphics.Clear([System.Drawing.Color]::White)
    $script:MapRects.Clear()

    $nodes = @($script:MapNodes | Where-Object { $_.Bytes -gt 0 } | Sort-Object Bytes -Descending | Select-Object -First 40)
    if ($nodes.Count -eq 0) {
        $message = "Nothing to draw yet.`n`nChoose a drive above and press Scan drive, or Whole drive scan."
        $Graphics.DrawString($message, $fontText, [System.Drawing.Brushes]::DimGray, [float]20, [float]18)
        return
    }

    $values = @()
    foreach ($node in $nodes) { $values += [double]$node.Bytes }
    $rects = Get-SquarifiedLayout -Values $values -X 4 -Y 4 -Width ([double][math]::Max($Bounds.Width - 8, 10)) -Height ([double][math]::Max($Bounds.Height - 8, 10))

    for ($index = 0; $index -lt $nodes.Count -and $index -lt $rects.Count; $index++) {
        $node = $nodes[$index]
        $rect = $rects[$index]
        $cell = New-Object System.Drawing.RectangleF([float]$rect.X, [float]$rect.Y, [float]$rect.W, [float]$rect.H)
        if ($cell.Width -lt 1 -or $cell.Height -lt 1) { continue }

        $brush = New-Object System.Drawing.SolidBrush((Get-NodeColor $index))
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [float]2)
        try {
            $Graphics.FillRectangle($brush, $cell)
            $Graphics.DrawRectangle($pen, $cell.X, $cell.Y, $cell.Width, $cell.Height)

            if ($cell.Width -gt 90 -and $cell.Height -gt 42) {
                $text = $node.Name
                if ($script:DeepMode) {
                    $parts = $node.Path.Split([System.IO.Path]::DirectorySeparatorChar)
                    if ($parts.Count -ge 2) { $text = "$($parts[$parts.Count - 2])\$($parts[$parts.Count - 1])" }
                }
                if ($text.Length -gt 32) { $text = $text.Substring(0, 29) + "..." }
                $Graphics.DrawString($text, $script:FontMap, [System.Drawing.Brushes]::Black, [float]($cell.X + 6), [float]($cell.Y + 4))
                if ($cell.Height -gt 62) {
                    $Graphics.DrawString((Format-Size $node.Bytes), $script:FontMap, [System.Drawing.Brushes]::Black, [float]($cell.X + 6), [float]($cell.Y + 22))
                }
            }
        } finally {
            $pen.Dispose()
            $brush.Dispose()
        }

        [void]$script:MapRects.Add([pscustomobject]@{ X = $rect.X; Y = $rect.Y; W = $rect.W; H = $rect.H; Node = $node })
    }
}

function Get-MapHit {
    param([int]$X, [int]$Y)
    foreach ($hit in $script:MapRects) {
        if ($X -ge $hit.X -and $X -le ($hit.X + $hit.W) -and $Y -ge $hit.Y -and $Y -le ($hit.Y + $hit.H)) { return $hit.Node }
    }
    return $null
}

# ---------------------------------------------------------------- dialogs

function Set-DialogBounds {
    param($Dialog, [int]$Width, [int]$Height)
    $area = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $w = [int][math]::Max(520, [math]::Min($Width, $area.Width - 24))
    $h = [int][math]::Max(420, [math]::Min($Height, $area.Height - 24))
    $Dialog.Size = New-Object System.Drawing.Size($w, $h)
    # If a small screen cuts the dialog short, scrollbars keep every control reachable.
    $Dialog.AutoScroll = $true
}

function Show-ExplanationDialog {
    param([string]$Heading, [string]$Meta, [string]$What, [string]$Why, [string]$Impact, [string]$Where)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Heading
    Set-DialogBounds $dialog 800 640
    $dialog.StartPosition = "CenterParent"
    $dialog.BackColor = [System.Drawing.Color]::White
    $dialog.Font = $fontBase
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.FormBorderStyle = "FixedDialog"

    $title = New-Object System.Windows.Forms.Label
    $title.Text = $Heading
    $title.Font = $fontHead
    $title.AutoSize = $false
    $title.Size = New-Object System.Drawing.Size(740, 44)
    $title.Location = New-Object System.Drawing.Point(22, 16)
    $dialog.Controls.Add($title)

    $metaLabel = New-Object System.Windows.Forms.Label
    $metaLabel.Text = $Meta
    $metaLabel.Font = $fontSmall
    $metaLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 112, 128)
    $metaLabel.AutoSize = $false
    $metaLabel.Size = New-Object System.Drawing.Size(740, 24)
    $metaLabel.Location = New-Object System.Drawing.Point(24, 62)
    $dialog.Controls.Add($metaLabel)

    $body = New-Object System.Windows.Forms.TextBox
    $body.Multiline = $true
    $body.ReadOnly = $true
    $body.ScrollBars = "Vertical"
    $body.BorderStyle = "FixedSingle"
    $body.Font = $fontText
    $body.BackColor = [System.Drawing.Color]::FromArgb(249, 251, 253)
    $body.Size = New-Object System.Drawing.Size(736, 440)
    $body.Location = New-Object System.Drawing.Point(24, 92)
    $body.Text = "WHAT IT IS`r`n$What`r`n`r`nWHY IT IS STILL HERE`r`n$Why`r`n`r`nIF YOU DELETE IT`r`n$Impact"
    if ($Where) { $body.Text += "`r`n`r`nWHERE IT IS`r`n$Where" }
    $dialog.Controls.Add($body)

    $close = New-Object System.Windows.Forms.Button
    $close.Text = "Close"
    $close.Font = $fontText
    $close.Size = New-Object System.Drawing.Size(150, 44)
    $close.Location = New-Object System.Drawing.Point(610, 542)
    $close.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($close)
    $dialog.AcceptButton = $close

    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
}

function Show-ItemDetails {
    if ($cacheList.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("Select an item in the list first.", "Disk Detective", "OK", "Information")
        return
    }
    $item = $cacheList.SelectedItems[0].Tag
    Show-ExplanationDialog -Heading $item.Title `
        -Meta "$(Get-RiskLabel $item.Risk)  |  $(Format-Size $item.Bytes)  |  last used $(Format-Age $item.LastUsed)" `
        -What $item.What -Why $item.Why -Impact $item.Impact -Where $item.Path
}

function Start-Elevated {
    param([string]$Command)
    try {
        $shell = "powershell.exe"
        Start-Process -FilePath $shell -Verb RunAs -ArgumentList "-NoProfile", "-Command", $Command
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("The administrator prompt was cancelled, so nothing was run.", "Disk Detective", "OK", "Information")
    }
}

function Show-Reserves {
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    Update-LiveStatus "Checking Windows reserves..."
    $reserves = @()
    try { $reserves = @(Get-SystemReserves -Progress { param($text) Update-LiveStatus $text }) }
    catch { }
    $form.Cursor = [System.Windows.Forms.Cursors]::Default

    if ($reserves.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("No extra Windows reserves were found on this PC.", "Windows reserves", "OK", "Information")
        return
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Windows reserves"
    Set-DialogBounds $dialog 920 680
    $dialog.StartPosition = "CenterParent"
    $dialog.BackColor = [System.Drawing.Color]::White
    $dialog.Font = $fontBase
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.FormBorderStyle = "FixedDialog"

    $heading = New-Object System.Windows.Forms.Label
    $heading.Text = "Space Windows keeps for itself"
    $heading.Font = $fontHead
    $heading.AutoSize = $true
    $heading.Location = New-Object System.Drawing.Point(20, 14)
    $dialog.Controls.Add($heading)

    $note = New-Object System.Windows.Forms.Label
    $note.Text = "These are not caches. Removing them changes how Windows behaves, so nothing here is done automatically."
    $note.Font = $fontSmall
    $note.ForeColor = [System.Drawing.Color]::FromArgb(100, 112, 128)
    $note.AutoSize = $false
    $note.Size = New-Object System.Drawing.Size(860, 22)
    $note.Location = New-Object System.Drawing.Point(24, 52)
    $dialog.Controls.Add($note)

    $list = New-Object System.Windows.Forms.ListView
    $list.View = "Details"
    $list.FullRowSelect = $true
    $list.Font = $fontText
    $list.Size = New-Object System.Drawing.Size(860, 260)
    $list.Location = New-Object System.Drawing.Point(24, 82)
    $list.MultiSelect = $false
    [void]$list.Columns.Add("Reserve", 260)
    [void]$list.Columns.Add("Size", 120, [System.Windows.Forms.HorizontalAlignment]::Right)
    [void]$list.Columns.Add("What it is", 460)
    foreach ($reserve in $reserves) {
        $row = New-Object System.Windows.Forms.ListViewItem($reserve.Name)
        if ($reserve.Bytes -gt 0) { [void]$row.SubItems.Add((Format-Size $reserve.Bytes)) } else { [void]$row.SubItems.Add("unknown") }
        [void]$row.SubItems.Add($reserve.What)
        $row.Tag = $reserve
        [void]$list.Items.Add($row)
    }
    $dialog.Controls.Add($list)

    $detail = New-Object System.Windows.Forms.TextBox
    $detail.Multiline = $true
    $detail.ReadOnly = $true
    $detail.ScrollBars = "Vertical"
    $detail.Font = $fontText
    $detail.BorderStyle = "FixedSingle"
    $detail.BackColor = [System.Drawing.Color]::FromArgb(249, 251, 253)
    $detail.Size = New-Object System.Drawing.Size(860, 160)
    $detail.Location = New-Object System.Drawing.Point(24, 354)
    $detail.Text = "Select a reserve above to read what it is and what to do."
    $dialog.Controls.Add($detail)

    $list.Add_SelectedIndexChanged({
        if ($list.SelectedItems.Count -eq 0) { return }
        $reserve = $list.SelectedItems[0].Tag
        $text = "WHAT IT IS`r`n$($reserve.What)`r`n`r`nWHY IT IS THERE`r`n$($reserve.Why)`r`n`r`nWHAT TO DO`r`n$($reserve.Action)"
        if ($reserve.Command) { $text += "`r`n`r`nCOMMAND (run only if you understand it)`r`n$($reserve.Command)" }
        $detail.Text = $text
    })

    $btnCleanup = New-Object System.Windows.Forms.Button
    $btnCleanup.Text = "Open Disk Cleanup"
    $btnCleanup.Font = $fontText
    $btnCleanup.Size = New-Object System.Drawing.Size(180, 44)
    $btnCleanup.Location = New-Object System.Drawing.Point(24, 528)
    $btnCleanup.FlatStyle = "Flat"
    $btnCleanup.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
    $dialog.Controls.Add($btnCleanup)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Run command as administrator"
    $btnRun.Font = $fontText
    $btnRun.Size = New-Object System.Drawing.Size(240, 44)
    $btnRun.Location = New-Object System.Drawing.Point(214, 528)
    $btnRun.FlatStyle = "Flat"
    $btnRun.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
    $dialog.Controls.Add($btnRun)

    $btnClose2 = New-Object System.Windows.Forms.Button
    $btnClose2.Text = "Close"
    $btnClose2.Font = $fontText
    $btnClose2.Size = New-Object System.Drawing.Size(140, 44)
    $btnClose2.Location = New-Object System.Drawing.Point(744, 528)
    $btnClose2.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($btnClose2)
    $dialog.AcceptButton = $btnClose2

    $btnCleanup.Add_Click({ try { Start-Process "cleanmgr.exe" } catch { } })
    $btnRun.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show("Select a reserve first.", "Disk Detective", "OK", "Information"); return }
        $reserve = $list.SelectedItems[0].Tag
        if (-not $reserve.Command) { [void][System.Windows.Forms.MessageBox]::Show("There is no command for this one. Read the note instead.", "Disk Detective", "OK", "Information"); return }
        $answer = [System.Windows.Forms.MessageBox]::Show("Run this as administrator?`n`n$($reserve.Command)`n`nOnly continue if you understand what it changes.", "Disk Detective", "YesNo", "Warning", "Button2")
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Start-Elevated $reserve.Command }
    })

    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
}

# ---------------------------------------------------------------- moving

$script:UiOperation = $false

# Every file-changing action takes this lock for its whole run. The buttons
# are already disabled while busy; this also covers status-bar links, dialogs
# and a second window, so two changes can never overlap.
function Begin-Change {
    if ($script:UiOperation) {
        [void][System.Windows.Forms.MessageBox]::Show("Another change is still running. Wait for it to finish, then try again.", "Disk Detective", "OK", "Information")
        return $false
    }
    if (-not (Enter-OperationLock)) {
        [void][System.Windows.Forms.MessageBox]::Show("Another Disk Detective window is changing files right now. Wait for it to finish, then try again.", "Disk Detective", "OK", "Information")
        return $false
    }
    $script:UiOperation = $true
    return $true
}

function End-Change {
    $script:UiOperation = $false
    Exit-OperationLock
}

function Start-MoveFolder {
    param([string[]]$Paths)

    $candidates = @()
    foreach ($path in $Paths) {
        if (-not $path -or -not (Test-Directory $path)) { continue }
        if (Test-ExcludedPath $path) {
            [void][System.Windows.Forms.MessageBox]::Show("You asked Disk Detective to leave this one alone:`n`n$path", "Disk Detective", "OK", "Information")
            return
        }
        $candidates += $path
    }
    if ($candidates.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("Select a folder first.", "Disk Detective", "OK", "Information")
        return
    }

    foreach ($path in $candidates) {
        $problem = Test-SafeToMove $path
        if ($problem) {
            [void][System.Windows.Forms.MessageBox]::Show("$path`n`n$problem", "This folder cannot be moved", "OK", "Warning")
            return
        }
    }

    $totalBytes = [int64]0
    $totalFiles = 0
    $statsMap = @{}
    Set-Busy $true
    try {
        foreach ($path in $candidates) {
            Update-LiveStatus "Measuring $path ..."
            $stats = Get-TreeStats $path
            $statsMap[$path] = $stats
            $totalBytes += $stats.Bytes
            $totalFiles += $stats.Files
        }
    } finally {
        Set-Busy $false
    }
    if ($form.IsDisposed) { return }
    $linkedPaths = @($candidates | Where-Object { [int]$statsMap[$_].Links -gt 0 })
    if ($linkedPaths.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show("These folders contain a shortcut or link inside them:`n`n$($linkedPaths -join "`n")`n`nDisk Detective cannot copy links safely, so nothing will be moved. Remove the link, or move the folder yourself.", "Folders with links cannot be moved", "OK", "Warning")
        return
    }
    if ($totalBytes -le 0) {
        [void][System.Windows.Forms.MessageBox]::Show("These folders are empty, so there is nothing to move.", "Disk Detective", "OK", "Information")
        return
    }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Choose where to keep the folder(s) - for example a folder on another drive."
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $destination = $dialog.SelectedPath
    if (-not $destination) { return }

    $destinationRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($destination))
    $sameDrivePaths = @()
    foreach ($path in $candidates) {
        $sourceRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($path))
        if ([string]::Equals($sourceRoot, $destinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $sameDrivePaths += $path }
    }
    if ($sameDrivePaths.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show("The new place is on the same drive as:`n`n$($sameDrivePaths -join "`n")`n`nMoving a folder inside one drive does not free any space there. Choose a folder on another drive.", "Choose another drive", "OK", "Warning")
        return
    }
    $free = Get-FreeSpace $destination
    $needed = [int64]($totalBytes * 1.05)
    if ($free -and $free.Total -gt 0 -and $free.Free -lt $needed) {
        [void][System.Windows.Forms.MessageBox]::Show("There is not enough room at the destination.`n`nNeed about $(Format-Size $needed), but only $(Format-Size $free.Free) is free.`n`nNothing was changed.", "Not enough free space", "OK", "Warning")
        return
    }

    $listText = ""
    $shown = 0
    foreach ($path in $candidates) {
        if ($shown -ge 6) { $listText += "`n  ...and $($candidates.Count - $shown) more"; break }
        $listText += "`n  $path"
        $shown++
    }

    $message = "Move $($candidates.Count) folder(s)?`n$listText`n`nTO:`n$destination`n`nTotal: $(Format-Size $totalBytes) in $($totalFiles) files.`n`nEach folder is copied, checked, and only then removed. A shortcut stays behind so programs keep working. Close any program that uses these folders first."
    $answer = [System.Windows.Forms.MessageBox]::Show($message, "Move folders to another drive", "YesNo", "Question", "Button2")
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    if (-not (Begin-Change)) { return }
    $freed = [int64]0
    $moved = 0
    $failures = @()
    try {
        Set-Busy $true
        foreach ($path in $candidates) {
            Update-LiveStatus "Moving $path ..."
            $result = Move-FolderWithLink -Source $path -DestinationParent $destination -KnownStats $statsMap[$path] -Progress { param($text) Update-LiveStatus $text }
            if ($result.Ok) {
                [void](Add-MoveRecord -Source $path -Target $result.Target -Bytes $result.Bytes -Files $result.Files)
                $freed += $result.Bytes
                $moved++
                if ($result.Leftover) { $failures += "The old copy of $path could not be fully removed: $($result.Leftover)" }
            } else {
                $failures += "$path - $($result.Message)"
            }
        }
    } finally {
        Set-Busy $false
        End-Change
    }

    $summary = "Moved $moved folder(s), freeing about $(Format-Size $freed)."
    if ($failures.Count -gt 0) {
        $summary += "`n`nProblems:"
        foreach ($failure in $failures) { $summary += "`n  - $failure" }
    }
    $summary += "`n`nYou can undo a move or repair a broken shortcut in the 'What I did' tab."
    [void][System.Windows.Forms.MessageBox]::Show($summary, "Disk Detective", "OK", "Information")

    if ($script:MapPath) {
        if ($script:DeepMode -and $script:Scan) {
            # Update the existing list instead of rescanning the whole drive.
            $script:MapNodes = @($script:Scan.Folders | Where-Object { Test-Path -LiteralPath $_.Path } | Select-Object -First 200)
            Fill-FolderList
            $mapPanel.Invalidate()
        } else {
            $script:MapHistory.Clear()
            Show-MapFolder -Path $script:MapPath
        }
    }
}

# ---------------------------------------------------------------- cache list

function Update-Headline {
    $safe = @($script:Items | Where-Object { $_.Risk -eq "safe" })
    $caution = @($script:Items | Where-Object { $_.Risk -eq "caution" })
    $protected = @($script:Items | Where-Object { $_.Risk -eq "protected" })
    $safeBytes = [int64]0
    foreach ($item in $safe) { $safeBytes += $item.Bytes }

    if ($script:Items.Count -eq 0) {
        $lblHeadline.Text = "Nothing worth cleaning up was found"
        $lblSub.Text = "Your PC is already tidy. Nothing has been changed."
    } elseif ($safe.Count -gt 0) {
        $lblHeadline.Text = "You can free up $(Format-Size $safeBytes) safely"
        $lblSub.Text = "$($safe.Count) safe item(s), easy to rebuild. $($caution.Count) need a look first; $($protected.Count) are protected and never deleted."
    } else {
        $lblHeadline.Text = "Nothing safe to remove was found"
        $lblSub.Text = "The items below need a decision from you before they go."
    }

    $btnClean.Enabled = ($safe.Count -gt 0)
}

function Get-FilteredItems {
    $filter = $cmbFilter.SelectedItem
    $map = @{
        "Safe to delete"      = "safe"
        "Low risk"            = "low"
        "Ask before deleting" = "caution"
        "Protected"           = "protected"
    }
    if ($filter -eq "Everything" -or -not $map.ContainsKey($filter)) {
        return @($script:Items | Sort-Object Bytes -Descending)
    }
    $risk = $map[$filter]
    return @($script:Items | Where-Object { $_.Risk -eq $risk } | Sort-Object Bytes -Descending)
}

function Update-CacheButtons {
    $ticked = @($cacheList.Items | Where-Object { $_.Checked })
    $btnDeleteChecked.Enabled = ($ticked.Count -gt 0)
    $btnDeleteChecked.Text = "Send ticked to Trash"
}

function Refresh-CacheList {
    $cacheList.BeginUpdate()
    try {
        $cacheList.Items.Clear()
        foreach ($item in (Get-FilteredItems)) {
            $row = New-Object System.Windows.Forms.ListViewItem($item.Name)
            [void]$row.SubItems.Add($item.Title)
            [void]$row.SubItems.Add((Format-Size $item.Bytes))
            [void]$row.SubItems.Add((Format-Age $item.LastUsed))
            [void]$row.SubItems.Add((Get-RiskLabel $item.Risk))
            $row.Tag = $item
            $row.ToolTipText = $item.Path
            $row.BackColor = $script:RiskColors[$item.Risk]
            [void]$cacheList.Items.Add($row)
        }
    } finally {
        $cacheList.EndUpdate()
    }
    Update-Headline
    Update-CacheButtons
}

function Remove-WithApproval {
    param([object[]]$Targets)

    $Targets = @($Targets | Where-Object { $_ -and $_.Risk -ne "protected" -and -not (Test-ExcludedPath $_.Path) })
    if ($Targets.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("There is nothing here that this app is allowed to remove.", "Disk Detective", "OK", "Information")
        return
    }

    $bytes = [int64]0
    foreach ($item in $Targets) { $bytes += $item.Bytes }
    $message = "Move $($Targets.Count) item(s), about $(Format-Size $bytes), to Disk Detective's Trash?`n`nThey are kept on the same drive and can be put back from the 'What I did' tab. Nothing is deleted for good unless you ask.`n`nDo you want to continue?"
    $answer = [System.Windows.Forms.MessageBox]::Show($message, "Move to Disk Detective's Trash?", "YesNo", "Question", "Button2")
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    if (-not (Begin-Change)) { return }
    Update-LiveStatus "Moving items to the Trash ..."
    try { $result = Move-ToQuarantine -Items $Targets -Reason "Cleaned up from the Clean up tab" }
    finally { End-Change }

    $removedPaths = @{}
    foreach ($entry in $result.Removed) { $removedPaths[$entry.Path] = $true }
    if ($result.Removed.Count -gt 0) {
        $script:Items = @($script:Items | Where-Object { -not $removedPaths.ContainsKey($_.Path) })
    }

    Refresh-CacheList
    Refresh-History

    $freedBytes = [int64]0
    foreach ($entry in $result.Removed) { $freedBytes += [int64]$entry.Bytes }

    $summary = ""
    if ($result.Removed.Count -gt 0) {
        $summary += "Moved $(Format-Size $freedBytes) to Disk Detective's Trash.`n`n$($result.Removed.Count) item(s) can be put back from the 'What I did' tab."
    } else {
        $summary += "Nothing was removed."
    }
    if ($result.Failed.Count -gt 0) {
        $summary += "`n`nSkipped:"
        $shown = 0
        foreach ($failure in $result.Failed) {
            if ($shown -ge 6) { $summary += "`n  ...and $($result.Failed.Count - $shown) more."; break }
            $summary += "`n  - $([System.IO.Path]::GetFileName($failure.Path)): $($failure.Reason)"
            $shown++
        }
    }
    [void][System.Windows.Forms.MessageBox]::Show($summary, "Disk Detective", "OK", "Information")
    $lblStatus.Text = "Done. Everything can be put back from 'What I did'."
}

# ---------------------------------------------------------------- duplicates

function Show-Duplicates {
    $root = Get-SelectedDriveRoot
    if (-not $root) { $root = $env:SystemDrive }
    if (-not $root) { $root = "C:\" }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Which folder should be checked for duplicate files? (The whole drive can take a long time.)"
    $dialog.SelectedPath = $root
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $searchRoot = $dialog.SelectedPath

    $script:CancelRequested = $false
    Set-Busy $true
    $groups = @()
    try {
        Update-LiveStatus "Comparing files in $searchRoot ..."
        $groups = @(Find-Duplicates -Root $searchRoot -Progress { param($path) $lblStatus.Text = "Comparing $path"; [System.Windows.Forms.Application]::DoEvents() } -ShouldStop { $script:CancelRequested })
    } catch {
        $groups = @()
        if (-not $script:CancelRequested) {
            [void][System.Windows.Forms.MessageBox]::Show("The duplicate check stopped: $($_.Exception.Message)", "Disk Detective", "OK", "Warning")
            Set-Busy $false
            return
        }
    } finally {
        Set-Busy $false
    }

    if ($form.IsDisposed) { return }
    if ($groups.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("No duplicate files were found in that folder.", "Disk Detective", "OK", "Information")
        return
    }

    $picker = New-Object System.Windows.Forms.Form
    $picker.Text = "Duplicate files"
    Set-DialogBounds $picker 980 700
    $picker.StartPosition = "CenterParent"
    $picker.BackColor = [System.Drawing.Color]::White
    $picker.Font = $fontBase
    $picker.MinimizeBox = $false
    $picker.MaximizeBox = $false
    $picker.FormBorderStyle = "FixedDialog"

    $heading = New-Object System.Windows.Forms.Label
    $heading.Text = "$($groups.Count) group(s) of identical files, $(Format-Size (Get-DuplicateWaste $groups)) could be freed"
    $heading.Font = $fontHead
    $heading.AutoSize = $false
    $heading.Size = New-Object System.Drawing.Size(920, 34)
    $heading.Location = New-Object System.Drawing.Point(18, 12)
    $picker.Controls.Add($heading)

    $note = New-Object System.Windows.Forms.Label
    $note.Text = "One copy of each group is left alone (the newest). Tick anything else you want moved to Disk Detective's Trash."
    $note.Font = $fontSmall
    $note.ForeColor = [System.Drawing.Color]::FromArgb(100, 112, 128)
    $note.AutoSize = $false
    $note.Size = New-Object System.Drawing.Size(920, 22)
    $note.Location = New-Object System.Drawing.Point(20, 50)
    $picker.Controls.Add($note)

    $dupList = New-Object System.Windows.Forms.ListView
    $dupList.View = "Details"
    $dupList.CheckBoxes = $true
    $dupList.FullRowSelect = $true
    $dupList.Font = $fontText
    $dupList.Size = New-Object System.Drawing.Size(924, 520)
    $dupList.Location = New-Object System.Drawing.Point(20, 80)
    [void]$dupList.Columns.Add("Duplicate file", 600)
    [void]$dupList.Columns.Add("Size", 110, [System.Windows.Forms.HorizontalAlignment]::Right)
    [void]$dupList.Columns.Add("Kept copy", 190)
    $picker.Controls.Add($dupList)

    foreach ($group in $groups) {
        # One copy is kept; the rest can go. No extra file reads here, so a file
        # disappearing mid-check cannot break the list.
        $keeper = $group.Files[0]
        $others = @($group.Files | Select-Object -Skip 1)
        foreach ($file in $others) {
            $row = New-Object System.Windows.Forms.ListViewItem($file.Path)
            [void]$row.SubItems.Add((Format-Size $file.Bytes))
            [void]$row.SubItems.Add($keeper.Path)
            $row.Tag = [pscustomobject]@{ Path = $file.Path; Bytes = $file.Bytes; Risk = "low"; Title = "Duplicate file" }
            [void]$dupList.Items.Add($row)
            $row.Checked = $true
        }
    }

    $btnDup = New-Object System.Windows.Forms.Button
    $btnDup.Text = "Send ticked to Trash"
    $btnDup.Font = $fontButton
    $btnDup.Size = New-Object System.Drawing.Size(260, 46)
    $btnDup.Location = New-Object System.Drawing.Point(20, 612)
    $btnDup.FlatStyle = "Flat"
    $btnDup.BackColor = [System.Drawing.Color]::FromArgb(34, 184, 132)
    $btnDup.ForeColor = [System.Drawing.Color]::White
    $picker.Controls.Add($btnDup)

    $btnClose3 = New-Object System.Windows.Forms.Button
    $btnClose3.Text = "Close"
    $btnClose3.Font = $fontText
    $btnClose3.Size = New-Object System.Drawing.Size(140, 46)
    $btnClose3.Location = New-Object System.Drawing.Point(804, 612)
    $btnClose3.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $picker.Controls.Add($btnClose3)
    $picker.AcceptButton = $btnClose3

    $btnDup.Add_Click({
        $ticked = @($dupList.CheckedItems | ForEach-Object { $_.Tag })
        if ($ticked.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show("Nothing is ticked.", "Disk Detective", "OK", "Information"); return }
        $bytes = [int64]0
        foreach ($item in $ticked) { $bytes += $item.Bytes }
        $answer = [System.Windows.Forms.MessageBox]::Show("Move $($ticked.Count) duplicate file(s), $(Format-Size $bytes), to Disk Detective's Trash? You can put them back from 'What I did'.", "Disk Detective", "YesNo", "Question", "Button2")
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        if (-not (Begin-Change)) { return }
        try { $result = Move-ToQuarantine -Items $ticked -Reason "Duplicate file" }
        finally { End-Change }
        [void][System.Windows.Forms.MessageBox]::Show("Moved $($result.Removed.Count) file(s) to the Trash. $($result.Failed.Count) could not be moved.", "Disk Detective", "OK", "Information")
        Refresh-History
        $picker.Close()
    })

    [void]$picker.ShowDialog($form)
    $picker.Dispose()
}

# ---------------------------------------------------------------- history

function Format-WhenText {
    param($Value)
    if (-not $Value) { return "" }
    try { return ([datetime]$Value).ToString("d MMM yyyy, HH:mm") } catch { return [string]$Value }
}

function Refresh-History {
    $historyList.BeginUpdate()
    try {
        $historyList.Items.Clear()
        foreach ($entry in @(Get-TrashEntries | Sort-Object At -Descending)) {
            $row = New-Object System.Windows.Forms.ListViewItem("Trashed: $($entry.Name)")
            [void]$row.SubItems.Add([string]$entry.OriginalPath)
            [void]$row.SubItems.Add((Format-Size ([int64]$entry.Bytes)))
            [void]$row.SubItems.Add((Format-WhenText $entry.At))
            [void]$row.SubItems.Add("In Disk Detective's Trash")
            $row.Tag = [pscustomobject]@{ Type = "trash"; Data = $entry }
            [void]$historyList.Items.Add($row)
        }

        foreach ($record in @(Get-MoveRecords | Sort-Object At -Descending)) {
            $health = Test-MoveHealth $record
            $statusText = "Works -> $($record.Target)"
            switch ($health.Status) {
                "ok" { $statusText = "Works -> $($record.Target)" }
                "missing-target" { $statusText = "BROKEN - data missing" }
                "not-a-link" { $statusText = "Not a shortcut any more" }
                "missing-source" { $statusText = "Old place is gone" }
                default { $statusText = $health.Text }
            }
            if ($record.Status -eq "undone") { $statusText = "Undone - data is back" }
            $row = New-Object System.Windows.Forms.ListViewItem("Moved: $([System.IO.Path]::GetFileName($record.Source))")
            [void]$row.SubItems.Add([string]$record.Source)
            [void]$row.SubItems.Add((Format-Size ([int64]$record.Bytes)))
            [void]$row.SubItems.Add((Format-WhenText $record.At))
            [void]$row.SubItems.Add($statusText)
            if ($health.Status -ne "ok" -and $record.Status -ne "undone") { $row.BackColor = [System.Drawing.Color]::FromArgb(253, 234, 237) }
            $row.Tag = [pscustomobject]@{ Type = "move"; Data = $record; Health = $health }
            [void]$historyList.Items.Add($row)
        }
    } finally {
        $historyList.EndUpdate()
    }

    $trash = @(Get-TrashEntries)
    $trashBytes = [int64]0
    foreach ($entry in $trash) { $trashBytes += [int64]$entry.Bytes }
    $moves = @(Get-MoveRecords)
    if ($trash.Count -eq 0 -and $moves.Count -eq 0) {
        $lblHistory.Text = "Nothing has been changed yet. Anything you remove or move will be listed here so you can undo it."
    } else {
        $lblHistory.Text = "Trash holds $(Format-Size $trashBytes) in $($trash.Count) item(s).   $($moves.Count) folder(s) have been moved."
    }
    Update-HistoryButtons
}

function Update-HistoryButtons {
    $selected = $null
    if ($historyList.SelectedItems.Count -gt 0) { $selected = $historyList.SelectedItems[0].Tag }
    $btnPutBack.Enabled = ($selected -and $selected.Type -eq "trash")
    $btnUndo.Enabled = ($selected -and $selected.Type -eq "move")
    $btnRepair.Enabled = ($selected -and $selected.Type -eq "move")
    $btnDeleteForever.Enabled = ($selected -and $selected.Type -eq "trash")
}

function Get-SelectedHistory {
    if ($historyList.SelectedItems.Count -eq 0) { return $null }
    return $historyList.SelectedItems[0].Tag
}

function Show-Ignored {
    $items = @(Get-Exclusions)
    if ($items.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("You have not asked Disk Detective to leave anything alone.", "Ignored folders", "OK", "Information")
        return
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Ignored folders"
    Set-DialogBounds $dialog 820 520
    $dialog.StartPosition = "CenterParent"
    $dialog.Font = $fontBase
    $dialog.BackColor = [System.Drawing.Color]::White
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.FormBorderStyle = "FixedDialog"

    $note = New-Object System.Windows.Forms.Label
    $note.Text = "These folders are hidden from scans and cannot be moved or removed."
    $note.Font = $fontSmall
    $note.AutoSize = $false
    $note.Size = New-Object System.Drawing.Size(760, 24)
    $note.Location = New-Object System.Drawing.Point(20, 14)
    $dialog.Controls.Add($note)

    $list = New-Object System.Windows.Forms.ListView
    $list.View = "Details"
    $list.FullRowSelect = $true
    $list.MultiSelect = $false
    $list.Font = $fontText
    $list.Size = New-Object System.Drawing.Size(760, 360)
    $list.Location = New-Object System.Drawing.Point(20, 44)
    [void]$list.Columns.Add("Folder", 520)
    [void]$list.Columns.Add("Ignored on", 210)
    $dialog.Controls.Add($list)

    foreach ($item in $items) {
        $row = New-Object System.Windows.Forms.ListViewItem([string]$item.Path)
        [void]$row.SubItems.Add((Format-WhenText $item.At))
        $row.Tag = $item
        [void]$list.Items.Add($row)
    }

    $btnForgive = New-Object System.Windows.Forms.Button
    $btnForgive.Text = "Stop ignoring"
    $btnForgive.Font = $fontText
    $btnForgive.Size = New-Object System.Drawing.Size(190, 44)
    $btnForgive.Location = New-Object System.Drawing.Point(20, 418)
    $btnForgive.FlatStyle = "Flat"
    $btnForgive.BackColor = [System.Drawing.Color]::FromArgb(242, 246, 251)
    $dialog.Controls.Add($btnForgive)

    $btnCloseIgnored = New-Object System.Windows.Forms.Button
    $btnCloseIgnored.Text = "Close"
    $btnCloseIgnored.Font = $fontText
    $btnCloseIgnored.Size = New-Object System.Drawing.Size(140, 44)
    $btnCloseIgnored.Location = New-Object System.Drawing.Point(640, 418)
    $btnCloseIgnored.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($btnCloseIgnored)
    $dialog.AcceptButton = $btnCloseIgnored

    $btnForgive.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        [void](Remove-Exclusion -Path $list.SelectedItems[0].Tag.Path)
        $list.SelectedItems[0].Remove()
        $lblStatus.Text = "That folder will be shown again next time."
    })

    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
}

# ---------------------------------------------------------------- events

$mapPanel.Add_Paint({
    param($sender, $eventArgs)
    Draw-Treemap -Graphics $eventArgs.Graphics -Bounds $sender.ClientRectangle
})

$mapPanel.Add_Resize({ $mapPanel.Invalidate() })

$mapPanel.Add_MouseClick({
    param($sender, $eventArgs)
    $node = Get-MapHit -X $eventArgs.X -Y $eventArgs.Y
    if ($node) { Select-MapNode $node }
})

$mapPanel.Add_MouseDoubleClick({
    param($sender, $eventArgs)
    $node = Get-MapHit -X $eventArgs.X -Y $eventArgs.Y
    if (-not $node -or $node.IsFile) { return }
    if ($node.IsLink -and $node.Target -and (Test-Directory $node.Target)) { Show-MapFolder -Path $node.Target -Remember }
    else { Show-MapFolder -Path $node.Path -Remember }
})

$folders.Add_SelectedIndexChanged({
    if ($progressBar.Visible) { return }
    $has = $folders.SelectedItems.Count -gt 0
    $btnMoveFolder.Enabled = $has
    $btnExplain.Enabled = $has
})

$folders.Add_MouseDoubleClick({
    if ($progressBar.Visible) { return }
    if ($folders.SelectedItems.Count -eq 0) { return }
    $node = $folders.SelectedItems[0].Tag
    if (-not $node -or $node.IsFile) { return }
    if ($node.IsLink -and $node.Target -and (Test-Directory $node.Target)) { Show-MapFolder -Path $node.Target -Remember }
    elseif (-not $node.IsLink) { Show-MapFolder -Path $node.Path -Remember }
})

$btnScanDrive.Add_Click({
    $root = Get-SelectedDriveRoot
    if (-not $root) {
        [void][System.Windows.Forms.MessageBox]::Show("No fixed drive was found.", "Disk Detective", "OK", "Warning")
        return
    }
    $script:MapHistory.Clear()
    $script:Scan = $null
    Show-MapFolder -Path $root
    $btnUp.Enabled = $false
})

$btnScanDeep.Add_Click({
    $root = Get-SelectedDriveRoot
    if (-not $root) {
        [void][System.Windows.Forms.MessageBox]::Show("No fixed drive was found.", "Disk Detective", "OK", "Warning")
        return
    }
    $script:CancelRequested = $false
    $script:CancelScan = $false
    Set-Busy $true
    try {
        Update-LiveStatus "Scanning the whole drive. This can take a few minutes..."
        $scan = Get-DriveScan -Root $root -FolderCount 300 -FileCount 100 `
            -Progress { param($path) $lblStatus.Text = "Looking in $path"; [System.Windows.Forms.Application]::DoEvents() } `
            -ShouldStop { $script:CancelRequested }
        if ($form.IsDisposed) { return }

        $script:Scan = $scan
        $script:DeepMode = $true
        $script:DeepFiles = @($scan.Files | Select-Object -First 60)
        $script:MapPath = $scan.Root
        $script:MapHistory.Clear()
        $script:MapNodes = @($scan.Folders | Select-Object -First 200)
        $script:MapRects.Clear()
        Fill-FolderList
        Update-Crumb
        $mapPanel.Invalidate()
        $btnUp.Enabled = $false
        $lblStatus.Text = "Found $(Format-Size $scan.FolderBytes) in $($scan.FolderFiles) files, $($scan.TotalFolders) folders. Click a row to select; double-click to open that folder."
    } catch {
        if ($script:CancelRequested -or $script:CancelScan) {
            $lblStatus.Text = "Scan stopped. Nothing was changed."
        } else {
            [void][System.Windows.Forms.MessageBox]::Show("The scan stopped: $($_.Exception.Message)", "Disk Detective", "OK", "Warning")
            $lblStatus.Text = "Scan stopped."
        }
    } finally {
        $script:CancelRequested = $false
        $script:CancelScan = $false
        Set-Busy $false
    }
})

$btnUp.Add_Click({
    if ($script:MapHistory.Count -eq 0) { return }
    $previous = $script:MapHistory.Pop()
    Show-MapFolder -Path $previous
    $btnUp.Enabled = ($script:MapHistory.Count -gt 0)
})

$btnMoveFolder.Add_Click({
    $paths = @()
    foreach ($row in $folders.SelectedItems) {
        if ($row.Tag -and -not $row.Tag.IsLink -and -not $row.Tag.IsFile) { $paths += $row.Tag.Path }
    }
    if ($paths.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("Select a normal folder (not a shortcut) in the list first.", "Disk Detective", "OK", "Information")
        return
    }
    Start-MoveFolder -Paths $paths
})

$btnExplain.Add_Click({
    if ($folders.SelectedItems.Count -eq 0) { return }
    $node = $folders.SelectedItems[0].Tag
    $explanation = Get-FolderExplanation $node.Path
    $meta = "$(Get-RiskLabel $explanation.Risk)  |  $(Format-Size $node.Bytes)  |  last used $(Format-Age $node.LastUsed)"
    Show-ExplanationDialog -Heading $explanation.Title -Meta $meta -What $explanation.What -Why $explanation.Why -Impact $explanation.Impact -Where $node.Path
})

$btnScanCaches.Add_Click({
    $script:CancelRequested = $false
    $script:CancelScan = $false
    $btnScanCaches.Text = "Scanning..."
    Set-Busy $true
    $script:Seen.Clear()
    $script:Candidates.Clear()
    $script:Roots.Clear()
    $script:Notes.Clear()
    $script:StatusCallback = {
        param($text)
        $lblStatus.Text = $text
        [System.Windows.Forms.Application]::DoEvents()
        if ($form.IsDisposed -or $script:CancelScan) { throw "Cancelled." }
    }

    try {
        $result = Get-ScanResult
        if ($form.IsDisposed) { return }
        if ($script:CancelScan) { $lblStatus.Text = "Scan stopped. Nothing was changed."; return }
        $script:Items = @(Remove-ExcludedItems $result.Items)
        $banner.Visible = $true
        $cleanActions.Visible = $true
        $script:CleanLayout.RowStyles[1].Height = 156
        $script:CleanLayout.RowStyles[2].Height = 60
        $btnClean.Left = [math]::Max(20, $banner.ClientSize.Width - $btnClean.Width - 30)
        $lblSub.Width = [math]::Max(280, $btnClean.Left - 36)
        Refresh-CacheList
        $lblStatus.Text = "Scan finished - $($script:Items.Count) item(s) found. Nothing has been changed."
    } catch {
        if ($script:CancelRequested -or $script:CancelScan) {
            $lblStatus.Text = "Scan stopped. Nothing was changed."
        } else {
            [void][System.Windows.Forms.MessageBox]::Show("The scan stopped: $($_.Exception.Message)", "Disk Detective", "OK", "Warning")
            $lblStatus.Text = "Scan stopped."
        }
    } finally {
        $script:CancelRequested = $false
        $script:CancelScan = $false
        Set-Busy $false
        if (-not $form.IsDisposed) { $btnScanCaches.Text = "Scan again" }
    }
})

$btnClean.Add_Click({
    $safe = @($script:Items | Where-Object { $_.Risk -eq "safe" })
    Remove-WithApproval -Targets $safe
})

$btnDetails.Add_Click({ Show-ItemDetails })
$cacheList.Add_MouseDoubleClick({ Show-ItemDetails })

$btnMoveCache.Add_Click({
    if ($cacheList.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("Select an item in the list first.", "Disk Detective", "OK", "Information")
        return
    }
    $item = $cacheList.SelectedItems[0].Tag
    Start-MoveFolder -Paths @($item.Path)
    if ((Get-LinkInfo $item.Path).IsLink) {
        # The item now lives on the other drive behind a shortcut, so drop it from the list.
        $script:Items = @($script:Items | Where-Object { $_.Path -ne $item.Path })
        Refresh-CacheList
    }
})

$btnIgnore.Add_Click({
    if ($cacheList.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("Select an item in the list first.", "Disk Detective", "OK", "Information")
        return
    }
    $item = $cacheList.SelectedItems[0].Tag
    [void](Add-Exclusion -Path $item.Path -Note $item.Title)
    $script:Items = @($script:Items | Where-Object { $_.Path -ne $item.Path })
    Refresh-CacheList
    $lblStatus.Text = "This one will be left alone from now on."
})

$btnDuplicates.Add_Click({ Show-Duplicates })
$btnReserves.Add_Click({ Show-Reserves })

$btnDeleteChecked.Add_Click({
    $ticked = @($cacheList.CheckedItems | ForEach-Object { $_.Tag })
    Remove-WithApproval -Targets $ticked
})

$cacheList.Add_ItemCheck({
    param($sender, $eventArgs)
    $tag = $sender.Items[$eventArgs.Index].Tag
    if ($tag -and $tag.Risk -eq "protected") {
        $eventArgs.NewValue = [System.Windows.Forms.CheckState]::Unchecked
        $lblStatus.Text = "Protected: save data is never deleted by this app."
    }
})

$cacheList.Add_ItemChecked({ Update-CacheButtons })
$cmbFilter.Add_SelectedIndexChanged({ Refresh-CacheList })

$historyList.Add_SelectedIndexChanged({ Update-HistoryButtons })

$btnPutBack.Add_Click({
    $selected = Get-SelectedHistory
    if (-not $selected -or $selected.Type -ne "trash") { return }
    if (-not (Begin-Change)) { return }
    try { $result = Restore-TrashEntry -Id $selected.Data.Id }
    finally { End-Change }
    [void][System.Windows.Forms.MessageBox]::Show($result.Message, "Disk Detective", "OK", "Information")
    Refresh-History
    if ($script:MapPath -and -not $script:DeepMode) { Show-MapFolder -Path $script:MapPath }
})

$btnUndo.Add_Click({
    $selected = Get-SelectedHistory
    if (-not $selected -or $selected.Type -ne "move") { return }
    $answer = [System.Windows.Forms.MessageBox]::Show("Copy the folder back and remove the shortcut?`n`n$($selected.Data.Source)", "Undo move", "YesNo", "Question", "Button2")
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    if (-not (Begin-Change)) { return }
    Set-Busy $true
    try {
        $result = Undo-Move -Id $selected.Data.Id -Progress { param($text) Update-LiveStatus $text }
    } finally {
        Set-Busy $false
        End-Change
    }
    [void][System.Windows.Forms.MessageBox]::Show($result.Message, "Disk Detective", "OK", "Information")
    Refresh-History
})

$btnRepair.Add_Click({
    $selected = Get-SelectedHistory
    if (-not $selected -or $selected.Type -ne "move") { return }
    $record = $selected.Data
    $newParent = ""
    if (-not (Test-Path -LiteralPath $record.Target)) {
        # Only ask for a folder when the recorded one has really gone.
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "The data folder is missing. Choose the folder that holds '$([System.IO.Path]::GetFileName($record.Target))' now."
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $newParent = $dialog.SelectedPath
    }

    if (-not (Begin-Change)) { return }
    Set-Busy $true
    try {
        $result = Repair-Move -Id $record.Id -NewParent $newParent -Progress { param($text) Update-LiveStatus $text }
    } finally {
        Set-Busy $false
        End-Change
    }
    [void][System.Windows.Forms.MessageBox]::Show($result.Message, "Disk Detective", "OK", "Information")
    Refresh-History
})

$btnDeleteForever.Add_Click({
    $selected = Get-SelectedHistory
    if (-not $selected -or $selected.Type -ne "trash") { return }
    $answer = [System.Windows.Forms.MessageBox]::Show("Delete this for good? It cannot be put back afterwards.`n`n$($selected.Data.OriginalPath)", "Delete for good", "YesNo", "Warning", "Button2")
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    if (-not (Begin-Change)) { return }
    try { $result = Remove-TrashEntry -Id $selected.Data.Id }
    finally { End-Change }
    [void][System.Windows.Forms.MessageBox]::Show($result.Message, "Disk Detective", "OK", "Information")
    Refresh-History
})

$btnCheckLinks.Add_Click({
    $records = @(Get-MoveRecords)
    if ($records.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("You have not moved any folders yet.", "Check shortcuts", "OK", "Information")
        return
    }
    $broken = @()
    foreach ($record in $records) {
        $health = Test-MoveHealth $record
        if ($health.Status -ne "ok" -and $record.Status -ne "undone") { $broken += "$($record.Source)`n   $($health.Text)" }
    }
    Refresh-History
    if ($broken.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("All $($records.Count) shortcut(s) are working.", "Check shortcuts", "OK", "Information")
    } else {
        [void][System.Windows.Forms.MessageBox]::Show("$($broken.Count) shortcut(s) need attention:`n`n$($broken -join "`n`n")`n`nSelect one in the list and press Repair shortcut.", "Check shortcuts", "OK", "Warning")
    }
})

$btnIgnored.Add_Click({ Show-Ignored })

$btnReport.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Save the report"
    $dialog.Filter = "Web page (*.html)|*.html"
    $dialog.FileName = "Disk-Detective-report.html"
    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $history = @()
    foreach ($entry in (Get-TrashEntries)) {
        $history += [pscustomobject]@{ What = "Trashed: $($entry.Name)"; Where = $entry.OriginalPath; Bytes = [int64]$entry.Bytes; When = (Format-WhenText $entry.At); Status = "In Trash" }
    }
    foreach ($record in (Get-MoveRecords)) {
        $history += [pscustomobject]@{ What = "Moved: $([System.IO.Path]::GetFileName($record.Source))"; Where = "$($record.Source) -> $($record.Target)"; Bytes = [int64]$record.Bytes; When = (Format-WhenText $record.At); Status = $record.Status }
    }

    $driveLabel = ""
    if ($script:MapPath) { $driveLabel = $script:MapPath }
    $written = Export-Report -Path $dialog.FileName -Scan $script:Scan -Items $script:Items -History $history -DriveLabel $driveLabel
    if ($written) {
        [void][System.Windows.Forms.MessageBox]::Show("Report saved to:`n$written", "Disk Detective", "OK", "Information")
    } else {
        [void][System.Windows.Forms.MessageBox]::Show("The report could not be saved there. Try another folder.", "Disk Detective", "OK", "Warning")
    }
})

$btnCancel.Add_Click({
    $script:CancelRequested = $true
    $script:CancelScan = $true
    $lblStatus.Text = "Stopping..."
})

$chkLarge.Add_Click({
    $currentDrive = Get-SelectedDriveRoot
    $driveLabel = ""
    if ($currentDrive) { $driveLabel = $currentDrive.TrimEnd('\') }
    Save-Settings -LargeText $chkLarge.Checked -LastDrive $driveLabel
    $answer = [System.Windows.Forms.MessageBox]::Show("The window will close and reopen with the new text size.", "Larger text", "YesNo", "Question")
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        # Let the replacement process take the single-instance lock.
        Release-SingleInstance
        try {
            Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", "`"$PSCommandPath`""
            $form.Close()
        } catch {
            try { $script:SingleInstanceOwned = $script:SingleInstanceMutex.WaitOne(0) } catch { }
            [void][System.Windows.Forms.MessageBox]::Show("Close Disk Detective and open it again to see the new text size.", "Larger text", "OK", "Information")
        }
    }
})

$btnAdminRestart.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show("Restart Disk Detective as administrator? Windows will ask for permission. This lets it see Windows' own temporary folders.", "Restart as administrator", "YesNo", "Question")
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    # Let the elevated process take the single-instance lock.
    Release-SingleInstance
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", "`"$PSCommandPath`""
        $form.Close()
    } catch {
        try { $script:SingleInstanceOwned = $script:SingleInstanceMutex.WaitOne(0) } catch { }
        [void][System.Windows.Forms.MessageBox]::Show("The administrator prompt was cancelled.", "Disk Detective", "OK", "Information")
    }
})

$cmbDrive.Add_SelectedIndexChanged({
    $root = Get-SelectedDriveRoot
    if (-not $root) { return }
    $label = $root.TrimEnd('\')
    Save-Settings -LargeText $chkLarge.Checked -LastDrive $label
})

$form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and $progressBar.Visible) {
        $script:CancelRequested = $true
        $eventArgs.SuppressKeyPress = $true
    }
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    # A normal close is held back so a half-done change is not abandoned. A
    # Windows shutdown is not blocked; the journal finishes the move next time.
    if ($script:UiOperation -and $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $eventArgs.Cancel = $true
        [void][System.Windows.Forms.MessageBox]::Show("A change is still running. Wait for it to finish before closing Disk Detective.", "Disk Detective", "OK", "Information")
    }
})

$form.Add_FormClosed({
    # Release before the process finishes so a quick reopen does not see a
    # stale lock. During an OS shutdown mid-move the process exit releases it.
    if (-not $script:UiOperation) { Release-SingleInstance }
})

$form.Add_Shown({
    # Fit the window on a small or scaled screen instead of hanging off the edge.
    $area = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $newWidth = [int][math]::Max($form.MinimumSize.Width, [math]::Min($form.Width, $area.Width - 24))
    $newHeight = [int][math]::Max($form.MinimumSize.Height, [math]::Min($form.Height, $area.Height - 24))
    $form.Size = New-Object System.Drawing.Size($newWidth, $newHeight)
    $form.Left = [math]::Max($area.X, $area.X + [int](($area.Width - $newWidth) / 2))
    $form.Top = [math]::Max($area.Y, $area.Y + [int](($area.Height - $newHeight) / 2))

    # Anchored controls are placed from the real window width, so they cannot
    # start off the edge on a narrow screen.
    $chkLarge.Left = [math]::Max(20, $header.ClientSize.Width - $chkLarge.Width - 40)
    $btnReserves.Left = [math]::Max(20, $cleanTop.ClientSize.Width - $btnReserves.Width - 20)
    $btnDuplicates.Left = [math]::Max(20, $btnReserves.Left - $btnDuplicates.Width - 10)

    Update-DriveList
    if (-not $UiSmoke) {
        try { $recovered = @(Repair-PendingMoves) } catch { $recovered = @() }
        if ($recovered.Count -gt 0) {
            $existingMoves = @(Get-MoveRecords)
            foreach ($item in $recovered) {
                if ($item.Completed) {
                    $already = @($existingMoves | Where-Object { $_.Source -eq $item.Source -and $_.Target -eq $item.Target })
                    if ($already.Count -eq 0) {
                        [void](Add-MoveRecord -Source $item.Source -Target $item.Target -Bytes $item.Bytes -Files $item.Files)
                    }
                }
            }
            $lines = @($recovered | ForEach-Object { $_.Message })
            [void][System.Windows.Forms.MessageBox]::Show("Disk Detective found changes that were interrupted by a crash or power loss.`n`n$($lines -join "`n`n")", "Recovered", "OK", "Information")
        }
    }
    Refresh-History
    $ready = "Choose a drive and press Scan drive."
    if (-not (Test-IsAdmin)) { $ready += " Some Windows folders need administrator." }
    Set-StatusText $ready
})

if ($UiSmoke) {
    # Used by the Windows check: build the whole window, show it, close it.
    $script:SmokeTimer = New-Object System.Windows.Forms.Timer
    $script:SmokeTimer.Interval = 1800
    $script:SmokeTimer.Add_Tick({
        $script:SmokeTimer.Stop()
        $form.Close()
    })
    $script:SmokeTimer.Start()
    [void]$form.ShowDialog()
    exit 0
}

[void]$form.ShowDialog()
