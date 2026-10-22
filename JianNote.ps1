param(
    [switch]$ValidateUi,
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$script:AppName = '简笺'
$script:AppVersion = '0.3.0'
$script:AppDataDirectory = if ($SelfTest) {
    Join-Path ([System.IO.Path]::GetTempPath()) ('JianNote-SelfTest-' + [Guid]::NewGuid().ToString('N'))
} else {
    Join-Path $env:LOCALAPPDATA 'JianNote'
}
$script:DataFile = Join-Path $script:AppDataDirectory 'notes.json'
$script:BackupFile = Join-Path $script:AppDataDirectory 'notes.backup.json'
$script:SettingsFile = Join-Path $script:AppDataDirectory 'settings.json'
$script:FirstRunMarkerFile = Join-Path $script:AppDataDirectory '.initialized'
$script:Notes = New-Object System.Collections.ArrayList
$script:SelectedNoteId = $null
$script:CurrentView = 'all'
$script:IsLoadingEditor = $false
$script:IsDark = $false
$script:PendingSave = $false
$script:IsMultiSelectMode = $false
$script:BodyFontSize = 15.0
$script:EmphasisFontSize = 18.0
$script:IsPreviewing = $false

function New-NoteObject {
    param(
        [string]$Title = '',
        [string]$Content = '',
        [string[]]$Tags = @(),
        [string]$RichContent = ''
    )

    $now = [DateTime]::UtcNow.ToString('o')
    [PSCustomObject]@{
        Id        = [Guid]::NewGuid().ToString('N')
        Title     = $Title
        Content     = $Content
        RichContent = $RichContent
        Tags        = @($Tags)
        IsPinned    = $false
        IsDeleted = $false
        CreatedAt = $now
        UpdatedAt = $now
    }
}

function ConvertTo-NormalizedNote {
    param([object]$InputObject)

    $now = [DateTime]::UtcNow.ToString('o')
    $id = if ($InputObject.PSObject.Properties['Id'] -and $InputObject.Id) { [string]$InputObject.Id } else { [Guid]::NewGuid().ToString('N') }
    $title = if ($InputObject.PSObject.Properties['Title']) { [string]$InputObject.Title } else { '' }
    $content = if ($InputObject.PSObject.Properties['Content']) { [string]$InputObject.Content } else { '' }
    $richContent = if ($InputObject.PSObject.Properties['RichContent']) { [string]$InputObject.RichContent } else { '' }
    $tags = if ($InputObject.PSObject.Properties['Tags']) { @($InputObject.Tags | ForEach-Object { [string]$_ }) } else { @() }
    $isPinned = if ($InputObject.PSObject.Properties['IsPinned']) { [bool]$InputObject.IsPinned } else { $false }
    $isDeleted = if ($InputObject.PSObject.Properties['IsDeleted']) { [bool]$InputObject.IsDeleted } else { $false }
    $createdAt = if ($InputObject.PSObject.Properties['CreatedAt'] -and $InputObject.CreatedAt) { [string]$InputObject.CreatedAt } else { $now }
    $updatedAt = if ($InputObject.PSObject.Properties['UpdatedAt'] -and $InputObject.UpdatedAt) { [string]$InputObject.UpdatedAt } else { $now }

    [PSCustomObject]@{
        Id        = $id
        Title     = $title
        Content     = $content
        RichContent = $richContent
        Tags        = $tags
        IsPinned  = $isPinned
        IsDeleted = $isDeleted
        CreatedAt = $createdAt
        UpdatedAt = $updatedAt
    }
}

function Ensure-DataDirectory {
    if (-not (Test-Path -LiteralPath $script:AppDataDirectory)) {
        New-Item -ItemType Directory -Path $script:AppDataDirectory -Force | Out-Null
    }
}

function Save-Notes {
    Ensure-DataDirectory
    $payload = [PSCustomObject]@{
        Version = 2
        SavedAt = [DateTime]::UtcNow.ToString('o')
        Notes   = @($script:Notes)
    } | ConvertTo-Json -Depth 8

    $tempFile = Join-Path $script:AppDataDirectory 'notes.tmp.json'

    # 另一个实例或安全软件可能短暂占用数据文件，重试几次再放弃，避免丢改动
    $attempt = 0
    while ($true) {
        try {
            [System.IO.File]::WriteAllText($tempFile, $payload, [System.Text.UTF8Encoding]::new($false))
            if (Test-Path -LiteralPath $script:DataFile) {
                Copy-Item -LiteralPath $script:DataFile -Destination $script:BackupFile -Force
            }
            Move-Item -LiteralPath $tempFile -Destination $script:DataFile -Force
            break
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            $attempt++
            if ($attempt -ge 3) { throw }
            Start-Sleep -Milliseconds 200
        }
    }

    $script:PendingSave = $false
}

function Load-Notes {
    Ensure-DataDirectory
    $isFirstLaunch = -not (Test-Path -LiteralPath $script:DataFile) -and -not (Test-Path -LiteralPath $script:SettingsFile) -and -not (Test-Path -LiteralPath $script:FirstRunMarkerFile)
    $script:Notes.Clear()

    if (Test-Path -LiteralPath $script:DataFile) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:DataFile, [System.Text.Encoding]::UTF8)
            $data = $raw | ConvertFrom-Json
            $items = if ($data.PSObject.Properties['Notes']) { @($data.Notes) } else { @($data) }
            foreach ($item in $items) {
                [void]$script:Notes.Add((ConvertTo-NormalizedNote $item))
            }
        }
        catch {
            $corruptFile = Join-Path $script:AppDataDirectory ("notes.corrupt.{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Copy-Item -LiteralPath $script:DataFile -Destination $corruptFile -Force
        }
    }

    if ($script:Notes.Count -eq 0 -and $isFirstLaunch) {
        $readmePath = Join-Path $PSScriptRoot 'README.md'
        if (Test-Path -LiteralPath $readmePath) {
            $welcomeContent = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)
            $welcome = New-NoteObject -Title 'README.md' -Content $welcomeContent -Tags @('说明')
        }
        else {
            $welcomeContent = "这是一个安静、快速、只属于你的本地笔记本。`r`n`r`n输入后会自动保存，Ctrl + N 新建，Ctrl + F 搜索。"
            $welcome = New-NoteObject -Title '欢迎使用简笺' -Content $welcomeContent -Tags @('开始')
        }
        [void]$script:Notes.Add($welcome)
        Save-Notes
    }

    if (-not (Test-Path -LiteralPath $script:FirstRunMarkerFile)) {
        [System.IO.File]::WriteAllText(
            $script:FirstRunMarkerFile,
            [DateTime]::UtcNow.ToString('o'),
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}

function Save-Settings {
    Ensure-DataDirectory
    $payload = @{ DarkMode = $script:IsDark } | ConvertTo-Json
    [System.IO.File]::WriteAllText($script:SettingsFile, $payload, [System.Text.UTF8Encoding]::new($false))
}

function Load-Settings {
    if (Test-Path -LiteralPath $script:SettingsFile) {
        try {
            $settings = [System.IO.File]::ReadAllText($script:SettingsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($settings.PSObject.Properties['DarkMode']) { $script:IsDark = [bool]$settings.DarkMode }
        }
        catch { $script:IsDark = $false }
    }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="简笺" Width="1180" Height="760" MinWidth="920" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#F6F7F9"
        FontFamily="Microsoft YaHei UI" FontSize="14">
  <Window.Resources>
    <SolidColorBrush x:Key="WindowBg" Color="#F6F7F9"/>
    <SolidColorBrush x:Key="PanelBg" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="NavBg" Color="#F0F2F5"/>
    <SolidColorBrush x:Key="PrimaryText" Color="#20242A"/>
    <SolidColorBrush x:Key="SecondaryText" Color="#78808B"/>
    <SolidColorBrush x:Key="Accent" Color="#4C6FFF"/>
    <SolidColorBrush x:Key="AccentSoft" Color="#E9EDFF"/>
    <SolidColorBrush x:Key="Border" Color="#E5E8EC"/>
    <SolidColorBrush x:Key="Hover" Color="#ECEFF3"/>
    <SolidColorBrush x:Key="Danger" Color="#E55353"/>
    <SolidColorBrush x:Key="EmphasisText" Color="#C62828"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource PrimaryText}"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource PrimaryText}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.72"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="Padding" Value="13,10"/>
    </Style>
    <Style x:Key="IconButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="FontSize" Value="17"/>
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Padding" Value="0"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource PrimaryText}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Accent}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
    </Style>
    <Style TargetType="RichTextBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource PrimaryText}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Accent}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" CornerRadius="10" Padding="12,10">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ItemBorder" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemBorder" Property="Background" Value="{DynamicResource AccentSoft}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Background="{DynamicResource WindowBg}">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="184"/>
      <ColumnDefinition Width="320"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <Border Grid.Column="0" Background="{DynamicResource NavBg}" Padding="16,22,12,16">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Orientation="Horizontal" Margin="8,0,0,24">
          <Border Width="28" Height="28" CornerRadius="8" Background="{DynamicResource Accent}">
            <TextBlock Text="简" Foreground="White" FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="简笺" Margin="10,0,0,0" FontSize="19" FontWeight="SemiBold" VerticalAlignment="Center"/>
        </StackPanel>
        <Button x:Name="NewNoteButton" Grid.Row="1" Margin="0,0,0,18" Padding="12,11" Background="{DynamicResource Accent}" Foreground="White" HorizontalContentAlignment="Center" FontWeight="SemiBold" Content="＋  新建笔记"/>
        <StackPanel Grid.Row="2">
          <Button x:Name="AllNotesButton" Style="{StaticResource NavButton}" Content="▤   全部笔记"/>
          <Button x:Name="PinnedButton" Style="{StaticResource NavButton}" Content="★   已置顶"/>
          <Button x:Name="TrashButton" Style="{StaticResource NavButton}" Content="⌫   回收站"/>
        </StackPanel>
        <StackPanel Grid.Row="3">
          <Button x:Name="ImportButton" Style="{StaticResource NavButton}" Content="⇧   导入文件" ToolTip="导入 .txt 或 .md"/>
          <Button x:Name="ExportAllButton" Style="{StaticResource NavButton}" Content="⇩   备份全部" ToolTip="导出 JSON 备份"/>
          <Button x:Name="ThemeButton" Style="{StaticResource NavButton}" Content="◐   深色模式"/>
          <TextBlock x:Name="StorageText" Margin="13,18,0,2" FontSize="11" Foreground="{DynamicResource SecondaryText}" Text="本地自动保存"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Column="1" Background="{DynamicResource PanelBg}" BorderBrush="{DynamicResource Border}" BorderThickness="0,0,1,0" Padding="18,20,14,12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid Margin="4,0,0,14">
          <TextBlock x:Name="ViewTitle" Text="全部笔记" FontSize="21" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <Button x:Name="MultiSelectButton" Content="多选" HorizontalAlignment="Right" Padding="10,5" FontSize="12"/>
          <Button x:Name="EmptyTrashButton" Content="清空回收站" HorizontalAlignment="Right" Padding="10,5" FontSize="12" Foreground="{DynamicResource Danger}" Visibility="Collapsed"/>
        </Grid>
        <Border Grid.Row="1" Background="{DynamicResource NavBg}" CornerRadius="9" Height="40" Margin="0,0,0,14">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="38"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Text="⌕" FontSize="20" Foreground="{DynamicResource SecondaryText}" VerticalAlignment="Center" HorizontalAlignment="Center"/>
            <TextBox x:Name="SearchBox" Grid.Column="1" Margin="0,1,10,0" VerticalContentAlignment="Center" FontSize="13" ToolTip="搜索标题、正文或标签（Ctrl+F）"/>
            <TextBlock x:Name="SearchHint" Grid.Column="1" Text="搜索笔记" Foreground="{DynamicResource SecondaryText}" VerticalAlignment="Center" IsHitTestVisible="False"/>
          </Grid>
        </Border>
        <Border x:Name="BatchBar" Grid.Row="2" Visibility="Collapsed" Background="{DynamicResource AccentSoft}" CornerRadius="9" Padding="9,5" Margin="0,0,0,10">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="BatchSelectionText" Text="已选 0 条" FontSize="12" VerticalAlignment="Center"/>
            <Button x:Name="BatchExportButton" Grid.Column="1" Content="导出" Padding="9,5" FontSize="12" IsEnabled="False"/>
            <Button x:Name="BatchDeleteButton" Grid.Column="2" Content="移入回收站" Padding="9,5" FontSize="12" Foreground="{DynamicResource Danger}" IsEnabled="False"/>
          </Grid>
        </Border>
        <Grid Grid.Row="3">
          <ListBox x:Name="NotesList" Background="Transparent" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Grid>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Text="{Binding DisplayTitle}" FontWeight="SemiBold" FontSize="14" TextTrimming="CharacterEllipsis"/>
                  <TextBlock Grid.Column="1" Text="{Binding PinMark}" Foreground="{DynamicResource Accent}" Margin="8,0,0,0"/>
                  <TextBlock Grid.Row="1" Grid.ColumnSpan="2" Text="{Binding Preview}" Foreground="{DynamicResource SecondaryText}" FontSize="12" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
                  <TextBlock Grid.Row="2" Grid.ColumnSpan="2" Text="{Binding Meta}" Foreground="{DynamicResource SecondaryText}" FontSize="11" Margin="0,7,0,0" TextTrimming="CharacterEllipsis"/>
                </Grid>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
          <StackPanel x:Name="EmptyListPanel" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center">
            <TextBlock Text="○" FontSize="30" Foreground="{DynamicResource SecondaryText}" HorizontalAlignment="Center"/>
            <TextBlock x:Name="EmptyListText" Text="还没有笔记" Foreground="{DynamicResource SecondaryText}" Margin="0,10,0,0"/>
          </StackPanel>
        </Grid>
        <TextBlock x:Name="NoteCountText" Grid.Row="4" Margin="4,8,0,0" Foreground="{DynamicResource SecondaryText}" FontSize="11" Text="0 条笔记"/>
      </Grid>
    </Border>

    <Grid Grid.Column="2" Background="{DynamicResource PanelBg}">
      <Grid x:Name="EditorPanel" Margin="42,20,42,18">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock x:Name="SaveStatus" Text="已保存" Foreground="{DynamicResource SecondaryText}" FontSize="11" VerticalAlignment="Center"/>
          <Button x:Name="PreviewButton" Grid.Column="1" Style="{StaticResource IconButton}" Width="52" FontSize="12" Content="预览" ToolTip="预览 Markdown 效果（Ctrl+P）"/>
          <Button x:Name="EmphasisButton" Grid.Column="2" Style="{StaticResource IconButton}" Width="52" FontSize="12" Content="重点" ToolTip="重点标记：选中文字后略微放大并标红，再点一次取消（Ctrl+B）"/>
          <Button x:Name="PinButton" Grid.Column="3" Style="{StaticResource IconButton}" Content="☆" ToolTip="置顶"/>
          <Button x:Name="ExportNoteButton" Grid.Column="4" Style="{StaticResource IconButton}" Content="↧" ToolTip="导出当前笔记"/>
          <Button x:Name="DeleteButton" Grid.Column="5" Style="{StaticResource IconButton}" Content="⌫" ToolTip="移到回收站"/>
        </Grid>
        <TextBox x:Name="TitleBox" Grid.Row="1" FontSize="28" FontWeight="SemiBold" Margin="0,22,0,6" Padding="0" AcceptsReturn="False" MaxLength="200"/>
        <TextBox x:Name="TagsBox" Grid.Row="2" FontSize="12" Foreground="{DynamicResource SecondaryText}" Margin="0,2,0,16" Padding="0" ToolTip="用逗号分隔标签"/>
        <RichTextBox x:Name="ContentBox" Grid.Row="3" FontSize="15" Padding="0,4,8,10" VerticalScrollBarVisibility="Auto" AcceptsTab="True" SpellCheck.IsEnabled="True" IsUndoEnabled="True">
          <RichTextBox.Resources>
            <Style TargetType="Paragraph">
              <Setter Property="LineHeight" Value="25"/>
              <Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>
              <Setter Property="Margin" Value="0"/>
            </Style>
          </RichTextBox.Resources>
          <FlowDocument PagePadding="0">
            <Paragraph LineHeight="25" LineStackingStrategy="BlockLineHeight" Margin="0"><Run/></Paragraph>
          </FlowDocument>
        </RichTextBox>
        <FlowDocumentScrollViewer x:Name="PreviewBox" Grid.Row="3" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Background="Transparent" BorderThickness="0" Padding="0,4,8,10" IsToolBarVisible="False"/>
        <Grid Grid.Row="4" Margin="0,10,0,0">
          <TextBlock x:Name="UpdatedText" Foreground="{DynamicResource SecondaryText}" FontSize="11"/>
          <TextBlock x:Name="StatsText" HorizontalAlignment="Right" Foreground="{DynamicResource SecondaryText}" FontSize="11"/>
        </Grid>
      </Grid>

      <StackPanel x:Name="NoSelectionPanel" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed">
        <TextBlock Text="✎" FontSize="38" Foreground="{DynamicResource SecondaryText}" HorizontalAlignment="Center"/>
        <TextBlock Text="选择一条笔记，或新建一条" Foreground="{DynamicResource SecondaryText}" Margin="0,14,0,0"/>
      </StackPanel>
      <StackPanel x:Name="MultiSelectionPanel" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed">
        <TextBlock Text="✓" FontSize="38" Foreground="{DynamicResource Accent}" HorizontalAlignment="Center"/>
        <TextBlock x:Name="MultiSelectionTitle" Text="已选择 0 条笔记" FontSize="18" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,14,0,0"/>
        <TextBlock Text="在左侧逐条点击，可同时选择多条笔记" Foreground="{DynamicResource SecondaryText}" Margin="0,8,0,0"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# 窗口与任务栏图标
$script:IconPath = Join-Path $PSScriptRoot '简笺.ico'
if (Test-Path -LiteralPath $script:IconPath) {
    try {
        $window.Icon = New-Object System.Windows.Media.Imaging.BitmapImage(New-Object System.Uri($script:IconPath))
    }
    catch {
        # 图标加载失败不影响使用
    }
}

if ($ValidateUi) {
    Write-Output 'UI validation passed.'
    exit 0
}

$controlNames = @(
    'NewNoteButton','AllNotesButton','PinnedButton','TrashButton','ImportButton','ExportAllButton','ThemeButton',
    'ViewTitle','MultiSelectButton','EmptyTrashButton','SearchBox','SearchHint','BatchBar','BatchSelectionText','BatchExportButton','BatchDeleteButton',
    'NotesList','EmptyListPanel','EmptyListText','NoteCountText','StorageText','EditorPanel','NoSelectionPanel','MultiSelectionPanel','MultiSelectionTitle',
    'SaveStatus','PreviewButton','EmphasisButton','PinButton','ExportNoteButton','DeleteButton','TitleBox','TagsBox','PreviewBox',
    'ContentBox','UpdatedText','StatsText'
)
foreach ($name in $controlNames) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}

function Set-BrushColor {
    param([string]$ResourceName, [string]$Color)
    $convertedColor = [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
    $window.Resources[$ResourceName] = [System.Windows.Media.SolidColorBrush]::new($convertedColor)
}

function Apply-Theme {
    if ($script:IsDark) {
        Set-BrushColor 'WindowBg' '#151719'
        Set-BrushColor 'PanelBg' '#1B1E21'
        Set-BrushColor 'NavBg' '#171A1D'
        Set-BrushColor 'PrimaryText' '#EDF0F3'
        Set-BrushColor 'SecondaryText' '#929AA5'
        Set-BrushColor 'Accent' '#7189FF'
        Set-BrushColor 'AccentSoft' '#293252'
        Set-BrushColor 'Border' '#2B2F34'
        Set-BrushColor 'Hover' '#25292E'
        Set-BrushColor 'Danger' '#FF7474'
        Set-BrushColor 'EmphasisText' '#FF6B6B'
        $ThemeButton.Content = '☀   浅色模式'
    }
    else {
        Set-BrushColor 'WindowBg' '#F6F7F9'
        Set-BrushColor 'PanelBg' '#FFFFFF'
        Set-BrushColor 'NavBg' '#F0F2F5'
        Set-BrushColor 'PrimaryText' '#20242A'
        Set-BrushColor 'SecondaryText' '#78808B'
        Set-BrushColor 'Accent' '#4C6FFF'
        Set-BrushColor 'AccentSoft' '#E9EDFF'
        Set-BrushColor 'Border' '#E5E8EC'
        Set-BrushColor 'Hover' '#ECEFF3'
        Set-BrushColor 'Danger' '#E55353'
        Set-BrushColor 'EmphasisText' '#C62828'
        $ThemeButton.Content = '◐   深色模式'
    }
}

function Get-NoteById {
    param([string]$Id)
    @($script:Notes | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
}

function Format-RelativeTime {
    param([string]$IsoDate)
    try {
        $date = [DateTime]::Parse($IsoDate).ToLocalTime()
        $span = (Get-Date) - $date
        if ($span.TotalMinutes -lt 1) { return '刚刚' }
        if ($span.TotalHours -lt 1) { return ('{0} 分钟前' -f [Math]::Floor($span.TotalMinutes)) }
        if ($span.TotalDays -lt 1) { return ('{0} 小时前' -f [Math]::Floor($span.TotalHours)) }
        if ($span.TotalDays -lt 7) { return ('{0} 天前' -f [Math]::Floor($span.TotalDays)) }
        return $date.ToString('yyyy年M月d日')
    }
    catch { return '' }
}

function Get-ListItem {
    param([object]$Note)
    $cleanContent = ([string]$Note.Content -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($cleanContent)) { $cleanContent = '暂无正文' }
    $tagText = if (@($Note.Tags).Count -gt 0) { '  ·  #' + (@($Note.Tags) -join ' #') } else { '' }
    [PSCustomObject]@{
        Id           = $Note.Id
        DisplayTitle = if ([string]::IsNullOrWhiteSpace($Note.Title)) { '无标题笔记' } else { $Note.Title.Trim() }
        Preview      = $cleanContent
        PinMark      = if ($Note.IsPinned) { '★' } else { '' }
        Meta         = (Format-RelativeTime $Note.UpdatedAt) + $tagText
    }
}

function Update-MultiSelectionState {
    $count = $NotesList.SelectedItems.Count
    $BatchSelectionText.Text = '已选 {0} 条' -f $count
    $MultiSelectionTitle.Text = '已选择 {0} 条笔记' -f $count
    $BatchExportButton.IsEnabled = $count -gt 0
    $BatchDeleteButton.IsEnabled = $count -gt 0
}

function Enter-MultiSelectMode {
    if ($script:CurrentView -ne 'all') { return }
    if ($script:PendingSave) { Commit-Editor }
    $script:IsMultiSelectMode = $true
    $script:SelectedNoteId = $null
    $NotesList.SelectionMode = [System.Windows.Controls.SelectionMode]::Multiple
    $NotesList.UnselectAll()
    $MultiSelectButton.Content = '取消'
    $BatchBar.Visibility = 'Visible'
    $EditorPanel.Visibility = 'Collapsed'
    $NoSelectionPanel.Visibility = 'Collapsed'
    $MultiSelectionPanel.Visibility = 'Visible'
    Update-MultiSelectionState
}

function Exit-MultiSelectMode {
    if (-not $script:IsMultiSelectMode) { return }
    $script:IsMultiSelectMode = $false
    $NotesList.UnselectAll()
    $NotesList.SelectionMode = [System.Windows.Controls.SelectionMode]::Single
    $MultiSelectButton.Content = '多选'
    $BatchBar.Visibility = 'Collapsed'
    $MultiSelectionPanel.Visibility = 'Collapsed'
    Show-NoSelection
}

function Get-SelectedNotes {
    $selectedIds = @($NotesList.SelectedItems | ForEach-Object { $_.Id })
    @($script:Notes | Where-Object { $selectedIds -contains $_.Id })
}

function Set-ViewButtonState {
    foreach ($button in @($AllNotesButton, $PinnedButton, $TrashButton)) {
        $button.Background = [System.Windows.Media.Brushes]::Transparent
        $button.FontWeight = [System.Windows.FontWeights]::Normal
    }
    $active = switch ($script:CurrentView) {
        'pinned' { $PinnedButton }
        'trash' { $TrashButton }
        default { $AllNotesButton }
    }
    $active.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'AccentSoft')
    $active.FontWeight = [System.Windows.FontWeights]::SemiBold
}

function Update-NotesList {
    param([switch]$KeepSelection)

    $selectedId = if ($KeepSelection) { $script:SelectedNoteId } else { $null }
    $query = $SearchBox.Text.Trim().ToLowerInvariant()
    $filtered = @($script:Notes | Where-Object {
        $candidate = $_
        $inView = switch ($script:CurrentView) {
            'pinned' { -not $candidate.IsDeleted -and $candidate.IsPinned }
            'trash' { $candidate.IsDeleted }
            default { -not $candidate.IsDeleted }
        }
        if (-not $inView) { return $false }
        if ([string]::IsNullOrWhiteSpace($query)) { return $true }
        $haystack = (([string]$candidate.Title) + "`n" + ([string]$candidate.Content) + "`n" + (@($candidate.Tags) -join ' ')).ToLowerInvariant()
        return $haystack.Contains($query)
    } | Sort-Object @{ Expression = 'IsPinned'; Descending = $true }, @{ Expression = { [DateTime]::Parse($_.UpdatedAt) }; Descending = $true })

    $NotesList.Items.Clear()
    foreach ($note in $filtered) { [void]$NotesList.Items.Add((Get-ListItem $note)) }
    $NoteCountText.Text = '{0} 条笔记' -f $filtered.Count
    $EmptyListPanel.Visibility = if ($filtered.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $NotesList.Visibility = if ($filtered.Count -eq 0) { 'Collapsed' } else { 'Visible' }
    $EmptyListText.Text = if ([string]::IsNullOrWhiteSpace($query)) {
        if ($script:CurrentView -eq 'trash') { '回收站是空的' } elseif ($script:CurrentView -eq 'pinned') { '还没有置顶笔记' } else { '还没有笔记' }
    } else { '没有找到匹配的笔记' }

    Set-ViewButtonState
    $MultiSelectButton.Visibility = if ($script:CurrentView -eq 'all') { 'Visible' } else { 'Collapsed' }
    $deletedCount = @($script:Notes | Where-Object { $_.IsDeleted }).Count
    $EmptyTrashButton.Visibility = if ($script:CurrentView -eq 'trash' -and $deletedCount -gt 0) { 'Visible' } else { 'Collapsed' }

    if ($script:IsMultiSelectMode) {
        Update-MultiSelectionState
        $EditorPanel.Visibility = 'Collapsed'
        $NoSelectionPanel.Visibility = 'Collapsed'
        $MultiSelectionPanel.Visibility = 'Visible'
        return
    }

    if ($selectedId) {
        foreach ($item in $NotesList.Items) {
            if ($item.Id -eq $selectedId) { $NotesList.SelectedItem = $item; $NotesList.ScrollIntoView($item); break }
        }
    }
    elseif ($NotesList.Items.Count -gt 0) {
        $NotesList.SelectedIndex = 0
    }
    else {
        $script:SelectedNoteId = $null
        Show-NoSelection
    }
}

function Show-NoSelection {
    $EditorPanel.Visibility = 'Collapsed'
    if ($script:IsMultiSelectMode) {
        $NoSelectionPanel.Visibility = 'Collapsed'
        $MultiSelectionPanel.Visibility = 'Visible'
    }
    else {
        $NoSelectionPanel.Visibility = 'Visible'
        $MultiSelectionPanel.Visibility = 'Collapsed'
    }
}

function New-EditorDocument {
    param([string]$Text = '')

    $document = [System.Windows.Documents.FlowDocument]::new()
    $document.PagePadding = [System.Windows.Thickness]::new(0)
    $normalized = if ($null -eq $Text) { '' } else { $Text -replace "`r`n", "`n" -replace "`r", "`n" }
    foreach ($line in ($normalized -split "`n", -1)) {
        $paragraph = [System.Windows.Documents.Paragraph]::new()
        $paragraph.LineHeight = 25
        $paragraph.LineStackingStrategy = [System.Windows.LineStackingStrategy]::BlockLineHeight
        $paragraph.Margin = [System.Windows.Thickness]::new(0)
        if ($line.Length -gt 0) {
            [void]$paragraph.Inlines.Add([System.Windows.Documents.Run]::new($line))
        }
        [void]$document.Blocks.Add($paragraph)
    }
    if ($document.Blocks.Count -eq 0) {
        [void]$document.Blocks.Add([System.Windows.Documents.Paragraph]::new())
    }
    return $document
}

function Get-EditorPlainText {
    $document = $ContentBox.Document
    if ($null -eq $document) { return '' }
    $range = [System.Windows.Documents.TextRange]::new($document.ContentStart, $document.ContentEnd)
    $text = [string]$range.Text
    if ($text.EndsWith("`r`n")) { return $text.Substring(0, $text.Length - 2) }
    if ($text.EndsWith("`n")) { return $text.Substring(0, $text.Length - 1) }
    return $text
}

function Set-EditorPlainText {
    param([string]$Text = '')
    $ContentBox.Document = New-EditorDocument -Text $Text
    $ContentBox.CaretPosition = $ContentBox.Document.ContentStart
}

function Set-EditorRichContent {
    param([object]$Note)
    $rich = [string]$Note.RichContent
    if (-not [string]::IsNullOrWhiteSpace($rich)) {
        try {
            $document = [System.Windows.Markup.XamlReader]::Parse($rich)
            if ($document -is [System.Windows.Documents.FlowDocument]) {
                $ContentBox.Document = $document
                $ContentBox.CaretPosition = $ContentBox.Document.ContentStart
                return
            }
        }
        catch {
            # 富文本损坏时退回纯文本，笔记仍然可以打开
        }
    }
    Set-EditorPlainText -Text ([string]$Note.Content)
}

function Test-EditorHasEmphasis {
    $document = $ContentBox.Document
    if ($null -eq $document) { return $false }
    foreach ($block in $document.Blocks) {
        if ($block -is [System.Windows.Documents.Paragraph]) {
            foreach ($inline in $block.Inlines) {
                if ($inline -is [System.Windows.Documents.Run] -and [Math]::Abs([double]$inline.FontSize - $script:EmphasisFontSize) -lt 0.5) {
                    return $true
                }
            }
        }
    }
    return $false
}

function Get-EditorRichContent {
    if (-not (Test-EditorHasEmphasis)) { return '' }
    return [System.Windows.Markup.XamlWriter]::Save($ContentBox.Document)
}

function Update-EmphasisBrush {
    $document = $ContentBox.Document
    if ($null -eq $document) { return }
    $brush = $window.Resources['EmphasisText']
    if ($null -eq $brush) { return }
    foreach ($block in $document.Blocks) {
        if ($block -is [System.Windows.Documents.Paragraph]) {
            foreach ($inline in $block.Inlines) {
                if ($inline -is [System.Windows.Documents.Run] -and [Math]::Abs([double]$inline.FontSize - $script:EmphasisFontSize) -lt 0.5) {
                    $inline.Foreground = $brush
                }
            }
        }
    }
}

function Get-MarkdownBrush {
    param([string]$Role)

    $color = switch ($Role) {
        'Code' { if ($script:IsDark) { '#9DB4C0' } else { '#B93B5A' } }
        'CodeBg' { if ($script:IsDark) { '#20252B' } else { '#F3F4F6' } }
        'Quote' { if ($script:IsDark) { '#A8B2BD' } else { '#6B7480' } }
        'Rule' { if ($script:IsDark) { '#3A3F45' } else { '#E3E6EA' } }
        'Heading' { if ($script:IsDark) { '#F2F5F8' } else { '#1B2027' } }
        'Link' { if ($script:IsDark) { '#8FA6FF' } else { '#4C6FFF' } }
        default { if ($script:IsDark) { '#DDE2E8' } else { '#282E36' } }
    }

    return [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($color))
}

function Add-MarkdownInlines {
    param(
        [System.Windows.Documents.Paragraph]$Target,
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return }

    $pattern = '`[^`]+`|\*\*[^*]+\*\*|\*[^*]+\*|\[[^\]]+\]\([^)]+\)'
    $position = 0

    foreach ($match in [regex]::Matches($Text, $pattern)) {
        if ($match.Index -gt $position) {
            [void]$Target.Inlines.Add([System.Windows.Documents.Run]::new($Text.Substring($position, $match.Index - $position)))
        }

        $token = $match.Value
        if ($token.Length -gt 2 -and $token.StartsWith('`')) {
            $run = [System.Windows.Documents.Run]::new($token.Substring(1, $token.Length - 2))
            $run.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
            $run.Foreground = Get-MarkdownBrush 'Code'
            [void]$Target.Inlines.Add($run)
        }
        elseif ($token.StartsWith('**') -and $token.Length -gt 4) {
            $run = [System.Windows.Documents.Run]::new($token.Substring(2, $token.Length - 4))
            $run.FontWeight = [System.Windows.FontWeights]::SemiBold
            [void]$Target.Inlines.Add($run)
        }
        elseif ($token.StartsWith('[') -and $token.Contains('](')) {
            $splitIndex = $token.IndexOf('](')
            $label = $token.Substring(1, $splitIndex - 1)
            $url = $token.Substring($splitIndex + 2, $token.Length - $splitIndex - 3)
            $link = [System.Windows.Documents.Hyperlink]::new()
            $link.Foreground = Get-MarkdownBrush 'Link'
            try { $link.NavigateUri = [Uri]$url } catch { }
            [void]$link.Inlines.Add([System.Windows.Documents.Run]::new($label))
            $link.Add_RequestNavigate({
                param($sender, $eventArgs)
                try { Start-Process $eventArgs.Uri.AbsoluteUri } catch { }
                $eventArgs.Handled = $true
            })
            [void]$Target.Inlines.Add($link)
        }
        elseif ($token.Length -gt 2 -and $token.StartsWith('*')) {
            $run = [System.Windows.Documents.Run]::new($token.Substring(1, $token.Length - 2))
            $run.FontStyle = [System.Windows.FontStyles]::Italic
            [void]$Target.Inlines.Add($run)
        }

        $position = $match.Index + $match.Length
    }

    if ($position -lt $Text.Length) {
        [void]$Target.Inlines.Add([System.Windows.Documents.Run]::new($Text.Substring($position)))
    }
}

function Add-PreviewCodeBlock {
    param(
        [System.Windows.Documents.FlowDocument]$Document,
        [object]$Lines
    )

    $items = @($Lines)
    if ($items.Count -eq 0) { return }

    $section = [System.Windows.Documents.Section]::new()
    $section.Background = Get-MarkdownBrush 'CodeBg'
    $section.Padding = [System.Windows.Thickness]::new(10, 8, 10, 8)
    $section.Margin = [System.Windows.Thickness]::new(0, 6, 0, 10)

    $paragraph = [System.Windows.Documents.Paragraph]::new()
    $paragraph.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
    $paragraph.FontSize = 13
    $paragraph.LineHeight = 20
    $paragraph.Margin = [System.Windows.Thickness]::new(0)
    [void]$paragraph.Inlines.Add([System.Windows.Documents.Run]::new(($items -join "`r`n")))
    [void]$section.Blocks.Add($paragraph)
    [void]$Document.Blocks.Add($section)
}

function ConvertTo-PreviewDocument {
    param([string]$Text)

    $document = [System.Windows.Documents.FlowDocument]::new()
    $document.PagePadding = [System.Windows.Thickness]::new(0)
    $document.FontFamily = [System.Windows.Media.FontFamily]::new('Microsoft YaHei UI')
    $document.FontSize = 15
    $document.Foreground = Get-MarkdownBrush 'Default'

    if ([string]::IsNullOrWhiteSpace($Text)) {
        $emptyParagraph = [System.Windows.Documents.Paragraph]::new()
        $emptyRun = [System.Windows.Documents.Run]::new('这条笔记还没有内容。')
        $emptyRun.Foreground = Get-MarkdownBrush 'Quote'
        [void]$emptyParagraph.Inlines.Add($emptyRun)
        [void]$document.Blocks.Add($emptyParagraph)
        return $document
    }

    $lines = $Text -split "\r?\n"
    $codeLines = New-Object System.Collections.ArrayList
    $inCode = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*```') {
            if ($inCode) {
                Add-PreviewCodeBlock -Document $document -Lines @($codeLines)
                $codeLines.Clear()
                $inCode = $false
            }
            else {
                $inCode = $true
            }
            continue
        }

        if ($inCode) {
            [void]$codeLines.Add($line)
            continue
        }

        if ($line -match '^\s*$') {
            $spacer = [System.Windows.Documents.Paragraph]::new()
            $spacer.Margin = [System.Windows.Thickness]::new(0)
            $spacer.FontSize = 7
            [void]$document.Blocks.Add($spacer)
            continue
        }

        if ($line -match '^(#{1,6})\s+(.*)$') {
            $level = $Matches[1].Length
            $headingSizes = @(26, 22, 19, 17, 16, 15)
            $paragraph = [System.Windows.Documents.Paragraph]::new()
            $paragraph.FontSize = $headingSizes[$level - 1]
            $paragraph.FontWeight = [System.Windows.FontWeights]::Bold
            $paragraph.Foreground = Get-MarkdownBrush 'Heading'
            $paragraph.LineHeight = $headingSizes[$level - 1] + 10
            if ($level -le 2) {
                $paragraph.Margin = [System.Windows.Thickness]::new(0, 10, 0, 4)
            }
            else {
                $paragraph.Margin = [System.Windows.Thickness]::new(0, 8, 0, 3)
            }
            Add-MarkdownInlines -Target $paragraph -Text $Matches[2]
            [void]$document.Blocks.Add($paragraph)
            continue
        }

        if ($line -match '^\s*[-*+]\s+(.*)$') {
            $paragraph = [System.Windows.Documents.Paragraph]::new()
            $paragraph.Margin = [System.Windows.Thickness]::new(18, 2, 0, 2)
            $paragraph.TextIndent = -14
            $bullet = [System.Windows.Documents.Run]::new('•  ')
            $bullet.Foreground = Get-MarkdownBrush 'Quote'
            [void]$paragraph.Inlines.Add($bullet)
            Add-MarkdownInlines -Target $paragraph -Text $Matches[1]
            [void]$document.Blocks.Add($paragraph)
            continue
        }

        if ($line -match '^\s*(\d+)\.\s+(.*)$') {
            $paragraph = [System.Windows.Documents.Paragraph]::new()
            $paragraph.Margin = [System.Windows.Thickness]::new(18, 2, 0, 2)
            $paragraph.TextIndent = -18
            [void]$paragraph.Inlines.Add([System.Windows.Documents.Run]::new(($Matches[1] + '.  ')))
            Add-MarkdownInlines -Target $paragraph -Text $Matches[2]
            [void]$document.Blocks.Add($paragraph)
            continue
        }

        if ($line -match '^\s*>\s?(.*)$') {
            $paragraph = [System.Windows.Documents.Paragraph]::new()
            $paragraph.Margin = [System.Windows.Thickness]::new(12, 4, 0, 6)
            $paragraph.Padding = [System.Windows.Thickness]::new(10, 2, 0, 2)
            $paragraph.BorderThickness = [System.Windows.Thickness]::new(3, 0, 0, 0)
            $paragraph.BorderBrush = Get-MarkdownBrush 'Rule'
            $quoteRun = [System.Windows.Documents.Run]::new($Matches[1])
            $quoteRun.FontStyle = [System.Windows.FontStyles]::Italic
            $quoteRun.Foreground = Get-MarkdownBrush 'Quote'
            [void]$paragraph.Inlines.Add($quoteRun)
            [void]$document.Blocks.Add($paragraph)
            continue
        }

        if ($line -match '^\s*([-*_]\s*){3,}$') {
            $ruleParagraph = [System.Windows.Documents.Paragraph]::new()
            $ruleParagraph.Margin = [System.Windows.Thickness]::new(0, 10, 0, 10)
            $ruleParagraph.BorderThickness = [System.Windows.Thickness]::new(0, 1, 0, 0)
            $ruleParagraph.BorderBrush = Get-MarkdownBrush 'Rule'
            [void]$document.Blocks.Add($ruleParagraph)
            continue
        }

        $paragraph = [System.Windows.Documents.Paragraph]::new()
        $paragraph.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $paragraph.LineHeight = 24
        $paragraph.LineStackingStrategy = [System.Windows.LineStackingStrategy]::BlockLineHeight
        Add-MarkdownInlines -Target $paragraph -Text $line
        [void]$document.Blocks.Add($paragraph)
    }

    if ($inCode -and $codeLines.Count -gt 0) {
        Add-PreviewCodeBlock -Document $document -Lines @($codeLines)
    }

    return $document
}

function Update-Preview {
    if (-not $script:IsPreviewing) { return }
    $PreviewBox.Document = ConvertTo-PreviewDocument -Text (Get-EditorPlainText)
}

function Toggle-Preview {
    if ($script:IsMultiSelectMode) { return }
    $note = Get-NoteById $script:SelectedNoteId
    if ($null -eq $note) { return }

    $script:IsPreviewing = -not $script:IsPreviewing

    if ($script:IsPreviewing) {
        if ($script:PendingSave) { Commit-Editor }
        $PreviewBox.Document = ConvertTo-PreviewDocument -Text (Get-EditorPlainText)
        $ContentBox.Visibility = 'Collapsed'
        $PreviewBox.Visibility = 'Visible'
        $PreviewButton.Content = '编辑'
        $PreviewButton.ToolTip = '回到编辑模式（Ctrl+P）'
    }
    else {
        $PreviewBox.Visibility = 'Collapsed'
        $ContentBox.Visibility = 'Visible'
        $PreviewButton.Content = '预览'
        $PreviewButton.ToolTip = '预览 Markdown 效果（Ctrl+P）'
        $ContentBox.Focus()
    }
}

function Set-Emphasis {
    if ($script:IsMultiSelectMode -or $script:IsPreviewing) { return }
    $note = Get-NoteById $script:SelectedNoteId
    if ($null -eq $note -or $note.IsDeleted) { return }

    $selection = $ContentBox.Selection
    if ($selection.IsEmpty) {
        $SaveStatus.Text = '请先选中要标记的文字'
        return
    }

    $fontSizeProperty = [System.Windows.Documents.TextElement]::FontSizeProperty
    $currentSize = $selection.GetPropertyValue($fontSizeProperty)
    $isEmphasized = ($currentSize -is [double]) -and ([Math]::Abs([double]$currentSize - $script:EmphasisFontSize) -lt 0.5)

    if ($isEmphasized) {
        $selection.ClearAllProperties()
    }
    else {
        $selection.ApplyPropertyValue($fontSizeProperty, $script:EmphasisFontSize)
        $brush = $window.Resources['EmphasisText']
        if ($null -ne $brush) {
            $selection.ApplyPropertyValue([System.Windows.Documents.TextElement]::ForegroundProperty, $brush)
        }
    }

    Commit-Editor
    $SaveStatus.Text = if ($isEmphasized) { '已取消重点标记' } else { '已标记为重点' }
    $ContentBox.Focus()
}

function Show-SelectedNote {
    $item = $NotesList.SelectedItem
    if ($null -eq $item) { Show-NoSelection; return }
    $note = Get-NoteById $item.Id
    if ($null -eq $note) { Show-NoSelection; return }

    $script:IsLoadingEditor = $true
    $script:SelectedNoteId = $note.Id
    $TitleBox.Text = [string]$note.Title
    Set-EditorRichContent -Note $note
    $TagsBox.Text = @($note.Tags) -join ', '
    $PinButton.Content = if ($note.IsDeleted) { '↶' } elseif ($note.IsPinned) { '★' } else { '☆' }
    $PinButton.ToolTip = if ($note.IsDeleted) { '恢复笔记' } elseif ($note.IsPinned) { '取消置顶' } else { '置顶' }
    $DeleteButton.Content = if ($note.IsDeleted) { '×' } else { '⌫' }
    $DeleteButton.ToolTip = if ($note.IsDeleted) { '永久删除' } else { '移到回收站' }
    $ExportNoteButton.IsEnabled = -not $note.IsDeleted
    $PinButton.IsEnabled = $true
    $TitleBox.IsReadOnly = $note.IsDeleted
    $TagsBox.IsReadOnly = $note.IsDeleted
    $ContentBox.IsReadOnly = $note.IsDeleted
    $SaveStatus.Text = if ($note.IsDeleted) { '回收站中的笔记' } else { '已保存' }
    $UpdatedText.Text = '更新于 ' + (Format-RelativeTime $note.UpdatedAt)
    Update-Stats
    $NoSelectionPanel.Visibility = 'Collapsed'
    $MultiSelectionPanel.Visibility = 'Collapsed'
    $EditorPanel.Visibility = 'Visible'
    if ($script:IsPreviewing) {
        $PreviewBox.Document = ConvertTo-PreviewDocument -Text (Get-EditorPlainText)
        $ContentBox.Visibility = 'Collapsed'
        $PreviewBox.Visibility = 'Visible'
        $PreviewButton.Content = '编辑'
        $PreviewButton.ToolTip = '回到编辑模式（Ctrl+P）'
    }
    else {
        $ContentBox.Visibility = 'Visible'
        $PreviewBox.Visibility = 'Collapsed'
        $PreviewButton.Content = '预览'
        $PreviewButton.ToolTip = '预览 Markdown 效果（Ctrl+P）'
    }
    $script:IsLoadingEditor = $false
}

function Update-Stats {
    $content = Get-EditorPlainText
    $nonSpaceChars = ($content -replace '\s', '').Length
    $lineCount = if ([string]::IsNullOrEmpty($content)) { 0 } else { ($content -split "`r?`n").Count }
    $StatsText.Text = '{0} 字  ·  {1} 行' -f $nonSpaceChars, $lineCount
}

function Refresh-CurrentListItem {
    $note = Get-NoteById $script:SelectedNoteId
    if ($null -eq $note) { return }
    $fresh = Get-ListItem $note
    foreach ($item in $NotesList.Items) {
        if ($item.Id -eq $note.Id) {
            $item.DisplayTitle = $fresh.DisplayTitle
            $item.Preview = $fresh.Preview
            $item.PinMark = $fresh.PinMark
            $item.Meta = $fresh.Meta
            $NotesList.Items.Refresh()
            break
        }
    }
}

function Queue-EditorSave {
    if ($script:IsLoadingEditor -or -not $script:SelectedNoteId) { return }
    $note = Get-NoteById $script:SelectedNoteId
    if ($null -eq $note -or $note.IsDeleted) { return }
    $script:PendingSave = $true
    $SaveStatus.Text = '正在编辑…'
    $saveTimer.Stop()
    $saveTimer.Start()
    Update-Stats
}

function Commit-Editor {
    if (-not $script:SelectedNoteId) { return }
    $note = Get-NoteById $script:SelectedNoteId
    if ($null -eq $note -or $note.IsDeleted) { return }

    $note.Title = $TitleBox.Text.Trim()
    $note.Content = Get-EditorPlainText
    $note.RichContent = Get-EditorRichContent
    $note.Tags = @($TagsBox.Text -split '[,，]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $note.UpdatedAt = [DateTime]::UtcNow.ToString('o')
    Save-Notes
    $SaveStatus.Text = '已保存'
    $UpdatedText.Text = '更新于 刚刚'
    Refresh-CurrentListItem
}

function New-Note {
    if ($script:IsMultiSelectMode) { Exit-MultiSelectMode }
    if ($script:PendingSave) { Commit-Editor }
    $note = New-NoteObject
    [void]$script:Notes.Add($note)
    $script:SelectedNoteId = $note.Id
    $script:CurrentView = 'all'
    $SearchBox.Clear()
    Save-Notes
    $ViewTitle.Text = '全部笔记'
    Update-NotesList -KeepSelection
    $TitleBox.Focus()
}

function Move-CurrentNoteToTrash {
    if ($script:PendingSave) { Commit-Editor }
    $note = Get-NoteById $script:SelectedNoteId
    if ($null -eq $note) { return }

    if (-not $note.IsDeleted) {
        $note.IsDeleted = $true
        $note.IsPinned = $false
        $note.UpdatedAt = [DateTime]::UtcNow.ToString('o')
        Save-Notes
        $script:SelectedNoteId = $null
        Update-NotesList
        return
    }

    $title = if ([string]::IsNullOrWhiteSpace($note.Title)) { '这条无标题笔记' } else { '“' + $note.Title + '”' }
    $prompt = "确定永久删除${title}吗？此操作无法撤销。"
    $answer = [System.Windows.MessageBox]::Show(
        $prompt,
        '永久删除',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::None
    )
    if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
        [void]$script:Notes.Remove($note)
        Save-Notes
        $script:SelectedNoteId = $null
        Update-NotesList
    }
}

function Restore-CurrentNote {
    $note = Get-NoteById $script:SelectedNoteId
    if ($null -eq $note -or -not $note.IsDeleted) { return }
    $note.IsDeleted = $false
    $note.UpdatedAt = [DateTime]::UtcNow.ToString('o')
    Save-Notes
    $script:SelectedNoteId = $null
    Update-NotesList
}

function ConvertTo-MarkdownText {
    param([object]$Note)
    $heading = if ([string]::IsNullOrWhiteSpace($Note.Title)) { '' } else { '# ' + $Note.Title + "`r`n`r`n" }
    $tags = if (@($Note.Tags).Count -gt 0) { "`r`n`r`n---`r`n" + ((@($Note.Tags) | ForEach-Object { '#' + $_ }) -join ' ') } else { '' }
    $heading + $Note.Content + $tags
}

function Get-SafeNoteFileName {
    param([object]$Note)
    $safeTitle = if ([string]::IsNullOrWhiteSpace($Note.Title)) { '无标题笔记' } else { $Note.Title -replace '[\\/:*?"<>|]', '_' }
    $safeTitle = $safeTitle.Trim().TrimEnd([char]'.')
    if ([string]::IsNullOrWhiteSpace($safeTitle)) { $safeTitle = '无标题笔记' }
    if ($safeTitle -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $safeTitle += '_' }
    if ($safeTitle.Length -gt 100) { $safeTitle = $safeTitle.Substring(0, 100) }
    if ($safeTitle.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) { return $safeTitle }
    $safeTitle + '.md'
}

function Get-UniqueExportPath {
    param([string]$Directory, [string]$FileName)
    $candidate = Join-Path $Directory $FileName
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $extension = [System.IO.Path]::GetExtension($FileName)
    $index = 2
    do {
        $candidate = Join-Path $Directory ('{0} ({1}){2}' -f $baseName, $index, $extension)
        $index++
    } while (Test-Path -LiteralPath $candidate)
    $candidate
}

function Export-SelectedNotes {
    $selectedNotes = @(Get-SelectedNotes)
    if ($selectedNotes.Count -eq 0) { return }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择导出所选笔记的文件夹'
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $exported = 0
    foreach ($note in $selectedNotes) {
        $fileName = Get-SafeNoteFileName $note
        $filePath = Get-UniqueExportPath -Directory $dialog.SelectedPath -FileName $fileName
        [System.IO.File]::WriteAllText($filePath, (ConvertTo-MarkdownText $note), [System.Text.UTF8Encoding]::new($true))
        $exported++
    }
    $StorageText.Text = '已导出 {0} 条笔记' -f $exported
}

function Move-SelectedNotesToTrash {
    $selectedNotes = @(Get-SelectedNotes)
    if ($selectedNotes.Count -eq 0) { return }
    $now = [DateTime]::UtcNow.ToString('o')
    foreach ($note in $selectedNotes) {
        $note.IsDeleted = $true
        $note.IsPinned = $false
        $note.UpdatedAt = $now
    }
    Save-Notes
    $count = $selectedNotes.Count
    Exit-MultiSelectMode
    $script:SelectedNoteId = $null
    Update-NotesList
    $StorageText.Text = '已将 {0} 条笔记移入回收站' -f $count
}

function Remove-AllDeletedNotes {
    $deletedNotes = @($script:Notes | Where-Object { $_.IsDeleted })
    foreach ($note in $deletedNotes) {
        [void]$script:Notes.Remove($note)
    }
    if ($deletedNotes.Count -gt 0) { Save-Notes }
    $deletedNotes.Count
}

function Clear-Trash {
    $deletedCount = @($script:Notes | Where-Object { $_.IsDeleted }).Count
    if ($deletedCount -eq 0) { return }

    $prompt = '确定永久删除回收站中的 {0} 条笔记吗？此操作无法撤销。' -f $deletedCount
    $answer = [System.Windows.MessageBox]::Show(
        $prompt,
        '清空回收站',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::None
    )
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $removedCount = Remove-AllDeletedNotes
    $script:SelectedNoteId = $null
    Update-NotesList
    $StorageText.Text = '已永久删除 {0} 条笔记' -f $removedCount
}

function Export-CurrentNote {
    if ($script:PendingSave) { Commit-Editor }
    $note = Get-NoteById $script:SelectedNoteId
    if ($null -eq $note) { return }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.FileName = Get-SafeNoteFileName $note
    $dialog.Filter = 'Markdown 文件 (*.md)|*.md|文本文件 (*.txt)|*.txt'
    if ($dialog.ShowDialog($window)) {
        [System.IO.File]::WriteAllText($dialog.FileName, (ConvertTo-MarkdownText $note), [System.Text.UTF8Encoding]::new($true))
    }
}

function Export-AllNotes {
    if ($script:PendingSave) { Commit-Editor }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.FileName = '简笺备份-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.json'
    $dialog.Filter = '简笺备份 (*.json)|*.json'
    if ($dialog.ShowDialog($window)) {
        $payload = [PSCustomObject]@{ Version = 1; ExportedAt = [DateTime]::UtcNow.ToString('o'); Notes = @($script:Notes) } | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($dialog.FileName, $payload, [System.Text.UTF8Encoding]::new($true))
        $SaveStatus.Text = '备份完成'
    }
}

function Import-Notes {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = '支持的文件 (*.txt;*.md;*.json)|*.txt;*.md;*.json|文本与 Markdown (*.txt;*.md)|*.txt;*.md|简笺备份 (*.json)|*.json'
    $dialog.Multiselect = $true
    if (-not $dialog.ShowDialog($window)) { return }

    $imported = 0
    foreach ($fileName in $dialog.FileNames) {
        try {
            $extension = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()
            if ($extension -eq '.json') {
                $data = [System.IO.File]::ReadAllText($fileName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $items = if ($data.PSObject.Properties['Notes']) { @($data.Notes) } else { @($data) }
                foreach ($item in $items) {
                    $note = ConvertTo-NormalizedNote $item
                    $note.Id = [Guid]::NewGuid().ToString('N')
                    [void]$script:Notes.Add($note)
                    $imported++
                }
            }
            else {
                $content = [System.IO.File]::ReadAllText($fileName, [System.Text.Encoding]::UTF8)
                $title = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                if ($extension -eq '.md' -and $content -match '^\s*#\s+([^\r\n]+)') {
                    $title = $Matches[1].Trim()
                    $content = $content -replace '^\s*#\s+[^\r\n]+\r?\n?', ''
                }
                [void]$script:Notes.Add((New-NoteObject -Title $title -Content $content))
                $imported++
            }
        }
        catch {
            [System.Windows.MessageBox]::Show(
                "无法导入：$fileName`r`n$($_.Exception.Message)",
                '导入失败',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
        }
    }

    if ($imported -gt 0) {
        Save-Notes
        $script:CurrentView = 'all'
        $ViewTitle.Text = '全部笔记'
        $SearchBox.Clear()
        Update-NotesList
        $StorageText.Text = "已导入 $imported 条笔记"
    }
}

$saveTimer = New-Object System.Windows.Threading.DispatcherTimer
$saveTimer.Interval = [TimeSpan]::FromMilliseconds(650)
$saveTimer.Add_Tick({
    $saveTimer.Stop()
    if ($script:PendingSave) { Commit-Editor }
})

$NewNoteButton.Add_Click({ New-Note })
$AllNotesButton.Add_Click({
    if ($script:PendingSave) { Commit-Editor }
    if ($script:IsMultiSelectMode) { Exit-MultiSelectMode }
    $script:CurrentView = 'all'; $ViewTitle.Text = '全部笔记'; Update-NotesList -KeepSelection
})
$PinnedButton.Add_Click({
    if ($script:PendingSave) { Commit-Editor }
    if ($script:IsMultiSelectMode) { Exit-MultiSelectMode }
    $script:CurrentView = 'pinned'; $ViewTitle.Text = '已置顶'; Update-NotesList -KeepSelection
})
$TrashButton.Add_Click({
    if ($script:PendingSave) { Commit-Editor }
    if ($script:IsMultiSelectMode) { Exit-MultiSelectMode }
    $script:CurrentView = 'trash'; $ViewTitle.Text = '回收站'; Update-NotesList
})
$NotesList.Add_SelectionChanged({
    if ($script:IsMultiSelectMode) {
        Update-MultiSelectionState
        return
    }
    if ($script:PendingSave) {
        $saveTimer.Stop()
        Commit-Editor
    }
    Show-SelectedNote
})
$SearchBox.Add_TextChanged({
    $SearchHint.Visibility = if ([string]::IsNullOrEmpty($SearchBox.Text)) { 'Visible' } else { 'Collapsed' }
    Update-NotesList -KeepSelection
})
$TitleBox.Add_TextChanged({ Queue-EditorSave })
$TagsBox.Add_TextChanged({ Queue-EditorSave })
$ContentBox.Add_TextChanged({ Queue-EditorSave })
$MultiSelectButton.Add_Click({
    if ($script:IsMultiSelectMode) {
        Exit-MultiSelectMode
        Update-NotesList
    }
    else {
        Enter-MultiSelectMode
    }
})
$BatchExportButton.Add_Click({ Export-SelectedNotes })
$BatchDeleteButton.Add_Click({ Move-SelectedNotesToTrash })
$EmptyTrashButton.Add_Click({ Clear-Trash })
$PreviewButton.Add_Click({ Toggle-Preview })
$EmphasisButton.Add_Click({ Set-Emphasis })
$PinButton.Add_Click({
    if ($script:PendingSave) { Commit-Editor }
    $note = Get-NoteById $script:SelectedNoteId
    if ($null -ne $note -and $note.IsDeleted) {
        Restore-CurrentNote
    }
    elseif ($null -ne $note) {
        $note.IsPinned = -not $note.IsPinned
        $note.UpdatedAt = [DateTime]::UtcNow.ToString('o')
        Save-Notes
        Update-NotesList -KeepSelection
        Show-SelectedNote
    }
})
$DeleteButton.Add_Click({ Move-CurrentNoteToTrash })
$DeleteButton.Add_MouseRightButtonUp({
    if ($script:CurrentView -eq 'trash') { Restore-CurrentNote }
})
$ExportNoteButton.Add_Click({ Export-CurrentNote })
$ExportAllButton.Add_Click({ Export-AllNotes })
$ImportButton.Add_Click({ Import-Notes })
$ThemeButton.Add_Click({
    $script:IsDark = -not $script:IsDark
    Apply-Theme
    if ($EditorPanel.Visibility -eq 'Visible') {
        Update-EmphasisBrush
        Update-Preview
        if ($script:SelectedNoteId) { $script:PendingSave = $true; $saveTimer.Start() }
    }
    Save-Settings
})

$window.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    $ctrl = [System.Windows.Input.Keyboard]::Modifiers.HasFlag([System.Windows.Input.ModifierKeys]::Control)
    $shift = [System.Windows.Input.Keyboard]::Modifiers.HasFlag([System.Windows.Input.ModifierKeys]::Shift)
    if ($ctrl -and $eventArgs.Key -eq 'N') { New-Note; $eventArgs.Handled = $true }
    elseif ($ctrl -and $eventArgs.Key -eq 'F') { $SearchBox.Focus(); $SearchBox.SelectAll(); $eventArgs.Handled = $true }
    elseif ($ctrl -and $eventArgs.Key -eq 'S') { if ($script:PendingSave) { Commit-Editor }; $SaveStatus.Text = '已保存'; $eventArgs.Handled = $true }
    elseif ($ctrl -and $eventArgs.Key -eq 'B' -and $ContentBox.IsKeyboardFocusWithin) { Set-Emphasis; $eventArgs.Handled = $true }
    elseif ($ctrl -and $eventArgs.Key -eq 'P') { Toggle-Preview; $eventArgs.Handled = $true }
    elseif ($ctrl -and $shift -and $eventArgs.Key -eq 'E') { Export-AllNotes; $eventArgs.Handled = $true }
    elseif ($ctrl -and $eventArgs.Key -eq 'E' -and $script:IsMultiSelectMode) { Export-SelectedNotes; $eventArgs.Handled = $true }
    elseif ($ctrl -and $eventArgs.Key -eq 'E') { Export-CurrentNote; $eventArgs.Handled = $true }
    elseif ($eventArgs.Key -eq 'Escape' -and $script:IsMultiSelectMode) { Exit-MultiSelectMode; Update-NotesList; $eventArgs.Handled = $true }
    elseif ($eventArgs.Key -eq 'Delete' -and $script:IsMultiSelectMode) { Move-SelectedNotesToTrash; $eventArgs.Handled = $true }
    elseif ($eventArgs.Key -eq 'Delete' -and $script:CurrentView -eq 'trash' -and -not $TitleBox.IsKeyboardFocusWithin -and -not $ContentBox.IsKeyboardFocusWithin) { Move-CurrentNoteToTrash; $eventArgs.Handled = $true }
})

$window.Add_Closing({
    if ($script:PendingSave) { Commit-Editor }
    Save-Settings
})

Load-Settings
Load-Notes
Apply-Theme
Update-NotesList

if ($SelfTest) {
    if ($script:Notes.Count -lt 1) { throw 'Self-test failed: no notes loaded.' }
    if ($NotesList.Items.Count -lt 1) { throw 'Self-test failed: note list was not rendered.' }
    if ($script:Notes[0].Title -ne 'README.md' -or -not $script:Notes[0].Content.Contains('# 简笺')) { throw 'Self-test failed: README.md was not loaded as the first note.' }
    $testNote = New-NoteObject -Title 'test' -Content 'content' -Tags @('tag')
    if (-not $testNote.Id -or $testNote.Title -ne 'test') { throw 'Self-test failed: note model invalid.' }
    [void]$script:Notes.Add($testNote)
    [void]$script:Notes.Add((New-NoteObject -Title 'second' -Content 'content'))
    Save-Notes
    Update-NotesList
    Enter-MultiSelectMode
    $NotesList.SelectAll()
    if ((@(Get-SelectedNotes)).Count -ne 3) { throw 'Self-test failed: multi-selection did not select every note.' }
    if (-not (ConvertTo-MarkdownText $testNote).Contains('# test')) { throw 'Self-test failed: batch export formatting is invalid.' }
    Move-SelectedNotesToTrash
    if (@($script:Notes | Where-Object { $_.IsDeleted }).Count -ne 3) { throw 'Self-test failed: selected notes were not moved to trash.' }
    $script:CurrentView = 'trash'
    $ViewTitle.Text = '回收站'
    Update-NotesList
    if ($EmptyTrashButton.Visibility -ne [System.Windows.Visibility]::Visible) { throw 'Self-test failed: empty-trash action was not shown.' }
    if ((Remove-AllDeletedNotes) -ne 3 -or $script:Notes.Count -ne 0) { throw 'Self-test failed: trash was not emptied.' }
    Update-NotesList
    if ($EmptyTrashButton.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw 'Self-test failed: empty-trash action remained visible.' }
    $script:Notes.Clear()
    Save-Notes
    Load-Notes
    if ($script:Notes.Count -ne 0) { throw 'Self-test failed: the first-run note returned after all notes were deleted.' }
    # 重点标记：纯文本往返与富文本序列化
    Set-EditorPlainText -Text '普通文字 重点文字'
    if ((Get-EditorPlainText) -ne '普通文字 重点文字') { throw 'Self-test failed: plain text round-trip lost characters.' }
    $emphasisParagraph = $ContentBox.Document.Blocks[0]
    $emphasisRun = $emphasisParagraph.Inlines[0]
    $emphasisRange = [System.Windows.Documents.TextRange]::new($emphasisRun.ContentStart, $emphasisRun.ContentEnd)
    $emphasisRange.ApplyPropertyValue([System.Windows.Documents.TextElement]::FontSizeProperty, $script:EmphasisFontSize)
    if (-not (Test-EditorHasEmphasis)) { throw 'Self-test failed: emphasis formatting was not detected.' }
    $emphasisXaml = Get-EditorRichContent
    if ([string]::IsNullOrWhiteSpace($emphasisXaml)) { throw 'Self-test failed: emphasis XAML was empty.' }
    $ContentBox.Document = [System.Windows.Markup.XamlReader]::Parse($emphasisXaml)
    if ((Get-EditorPlainText) -ne '普通文字 重点文字') { throw 'Self-test failed: emphasis round-trip changed the text.' }
    if (-not (Test-EditorHasEmphasis)) { throw 'Self-test failed: emphasis was lost after round-trip.' }
    Set-EditorPlainText -Text ''

    # 重点标记要随笔记一起保存，并在重新读取后还原
    $script:Notes.Clear()
    $richNote = New-NoteObject -Title '重点标记自测' -Content '普通文字 重点文字'
    $richNote.RichContent = $emphasisXaml
    [void]$script:Notes.Add($richNote)
    Save-Notes
    Load-Notes
    $reloadedNote = @($script:Notes | Where-Object { $_.Title -eq '重点标记自测' }) | Select-Object -First 1
    if ($null -eq $reloadedNote) { throw 'Self-test failed: note with emphasis was not saved.' }
    if ([string]::IsNullOrWhiteSpace([string]$reloadedNote.RichContent)) { throw 'Self-test failed: RichContent was not persisted to disk.' }
    if ([string]$reloadedNote.Content -ne '普通文字 重点文字') { throw 'Self-test failed: plain text was not persisted next to RichContent.' }

    # Markdown 预览渲染
    $sampleMarkdown = @'
# 标题一

## 标题二

- 列表项
- 带 **加粗** 与 `代码` 的项

> 一段引用

1. 有序一
2. 有序二

```powershell
Write-Host 'hi'
```

---

普通段落，含 [链接](https://github.com)。
'@
    $previewDocument = ConvertTo-PreviewDocument -Text $sampleMarkdown
    if ($previewDocument.Blocks.Count -lt 8) { throw 'Self-test failed: markdown preview produced too few blocks.' }
    $previewText = ([System.Windows.Documents.TextRange]::new($previewDocument.ContentStart, $previewDocument.ContentEnd)).Text
    foreach ($expected in @('标题一', '列表项', '一段引用', '有序一', 'Write-Host', '普通段落')) {
        if (-not $previewText.Contains($expected)) { throw "Self-test failed: markdown preview lost '$expected'." }
    }
    $script:IsPreviewing = $false

    Write-Output ("Self-test passed. Loaded {0} note(s)." -f $script:Notes.Count)
    Remove-Item -LiteralPath $script:AppDataDirectory -Recurse -Force
    exit 0
}

[void]$window.ShowDialog()

