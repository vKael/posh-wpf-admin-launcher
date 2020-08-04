    param(
        [Parameter(Mandatory=$false)] [string] $OverrideConfig,
        # UI -Command fix, not an actal parameter
        [string] $Command
    )
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $GUI_TITLE = "DynamicGUI"
    $GUI_WIDTH = 400
    $GUI_HEIGHT = 200
    $GUI_ROWS = 3
    $GUI_COLUMNS = 3
    $GUI_RESIZE = "NoResize"
    $CONFIG_PATH = "H:\"
    $CONFIG_NAME = "config.ini"
    $MASTERKEY_NAME = "master.key"
    $ADMIN_SUFFIX = ".adm.crd"
    function Get-IniFile {    
        param(
            [parameter(Mandatory = $true)] [string] $filePath,
            [string] $anonymous = 'NoSection',
            [switch] $comments,
            [string] $commentsSectionsSuffix = '_',
            [string] $commentsKeyPrefix = 'Comment'
        )
        $ini = [Ordered]@{}
        switch -regex -file ($filePath) {
            "^\[(.+)\]$" {
                # Section
                $section = $matches[1]
                $ini[$section] = [Ordered]@{}
                $CommentCount = 0
                if ($comments) {
                    $commentsSection = $section + $commentsSectionsSuffix
                    $ini[$commentsSection] = [Ordered]@{}
                }
                continue
            }
            "^(;.*)$" {
                # Comment
                if ($comments) {
                    if (!($section)) {
                        $section = $anonymous
                        $ini[$section] = @{}
                    }
                    $value = $matches[1]
                    $CommentCount = $CommentCount + 1
                    $name = $commentsKeyPrefix + $CommentCount
                    $commentsSection = $section + $commentsSectionsSuffix
                    $ini[$commentsSection][$name] = $value
                }
                continue
            }
            "^(.+?)\s*=\s*(.*)$" {
                # Key
                if (!($section)) {
                    $section = $anonymous
                    $ini[$section] = @{}
                }
                $name, $value = $matches[1..2]
                $ini[$section][$name] = $value
                continue
            }
        }
        return $ini
    }
    function escapeDoubleQuote {
        param(
            [parameter(Mandatory = $true)] [array] $commands
        )
        for ( $i = 0; $i -lt $commands.Count; $i++ ) {   
            $commands[$i] = $commands[$i].Replace("`"", "`"`"`"")
        }
        return $commands
    }
    function ReplaceInArray {
        param(
            [parameter(Mandatory = $true)] [array] $Array,
            [parameter(Mandatory = $true)] [String] $Keyword,
            [parameter(Mandatory = $true)] [String] $Replacement
        )
        for ( $i = 0; $i -lt $Array.Count; $i++ ) {   
            $Array[$i] = $Array[$i].Replace($Keyword, $Replacement)
        }
        return $Array
    }
    function GetCredential {
        param(
            [parameter(Mandatory = $true)] [String] $Username,
            [parameter(Mandatory = $true)] [String] $Master,
            [parameter(Mandatory = $true)] [String] $Credential
        )
        return (New-Object System.Management.Automation.PSCredential($Username, (Get-Content $Credential | ConvertTo-SecureString -Key (Get-Content($Master)))))
    }
    function CreateCredential {
        param(
            [parameter(Mandatory = $true)] [String] $Username,
            [parameter(Mandatory = $true)] [String] $Master,
            [parameter(Mandatory = $true)] [String] $Credential
        )
        $Key = New-Object Byte[] 32
        [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Key)
        $Key | Out-File $Master
        (Get-Credential $Username).Password | ConvertFrom-SecureString -Key (Get-Content $Master) | Set-Content $Credential
    }   
    # Unique ID for UI/UX
    $GlobalID = 0
    # Dedicated hashmap for onClick scripts to avoid looping on all INI again
    $OnClickScripts = @{}
    # Load INI file
    if ( $OverrideConfig -eq "" ) {
        $ConfigComputedPath = Join-Path -Path ($CONFIG_PATH) -ChildPath $CONFIG_NAME
     }
    else {    
        $ConfigComputedPath = $OverrideConfig
    }
    if ( Test-Path $ConfigComputedPath ) {
        $Config = Get-IniFile ($ConfigComputedPath)
    }
    else {
        [System.Windows.MessageBox]::Show("Unable to load $ConfigComputedPath")
    }
    # Default values management
    if ( $Config["Global"]["Home"] -eq $null ) { $Config["Global"]["Home"] = $MyInvocation.MyCommand.Path }
    if ( $Config["Global"]["Title"] -eq $null ) { $Config["Global"]["Title"] = $GUI_TITLE }
    if ( $Config["Global"]["Width"] -eq $null ) { $Config["Global"]["Width"] = $GUI_WIDTH }
    if ( $Config["Global"]["Height"] -eq $null ) { $Config["Global"]["Height"] = $GUI_HEIGHT }
    if ( $Config["Global"]["Rows"] -eq $null ) { $Config["Global"]["Rows"] = $GUI_ROWS }
    if ( $Config["Global"]["Columns"] -eq $null ) { $Config["Global"]["Columns"] = $GUI_COLUMNS }
    if ( $Config["Global"]["Resize"] -eq $null ) { $Config["Global"]["Resize"] = $GUI_RESIZE }
    # Rights management
    $WindowsIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $Domain, $Username = $WindowsIdentity.Name.Split("\")
    $WindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($WindowsIdentity)
    $Administrators = [System.Security.Principal.WindowsBuiltInRole]::Administrator
    $RunAs = ($WindowsIdentity.Name +".adm")
    # Elevate with current config as parameter if no admin token
    if ( -not ($WindowsPrincipal.IsInRole($Administrators)) ) {
        $UNCConfigPath = Join-Path -Path ($Config["Global"]["Home"] + $Username) -ChildPath ($CONFIG_NAME)
        $SelfElevatedCommand = ("Start-Process -WindowStyle Hidden -WorkingDirectory 'C:\Windows\SysWOW64\WindowsPowerShell\v1.0' -FilePath 'powershell.exe' -Verb runAs -ArgumentList '{0}', \""'{1}'\""" -f $MyInvocation.MyCommand.Definition, $UNCConfigPath)
        # Credential management
        $KeyPath = Join-Path -Path ($Config["Global"]["Home"] + $Username) -ChildPath ($MASTERKEY_NAME)
        $CredentialPath = Join-Path -Path ($Config["Global"]["Home"] + $Username) -ChildPath ($Username + $ADMIN_SUFFIX)
        if ( -not (Test-Path $KeyPath) -or -not (Test-Path $CredentialPath) ) {
            [System.Windows.MessageBox]::Show("No credential found. Creating.")
            
            CreateCredential $RunAs $KeyPath $CredentialPath
        }
        $Credentials = GetCredential $RunAs $KeyPath $CredentialPath
        $DS = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('domain')
        
        While ( $DS.ValidateCredentials($Credentials.GetNetworkCredential().UserName, $Credentials.GetNetworkCredential().Password) -eq $false ) {
            [System.Windows.MessageBox]::Show("Invalid credential found for $RunAs. Re-creating.")
            
            CreateCredential $RunAs $KeyPath $CredentialPath
            $Credentials = GetCredential $RunAs $KeyPath $CredentialPath
        }
        Start-Process -WorkingDirectory "C:\Windows\SysWOW64\WindowsPowerShell\v1.0" -FilePath "powershell.exe" -Credential $Credentials -ArgumentList $SelfElevatedCommand
    }
    # UI generation
    else {
        $Form = New-Object System.Xml.XmlDocument
        $Window = $Form.CreateNode("element", "Window", $null)
        $Window.SetAttribute("xmlns", "http://schemas.microsoft.com/winfx/2006/xaml/presentation") | Out-Null
        $Window.SetAttribute("xmlns:x", "http://schemas.microsoft.com/winfx/2006/xaml") | Out-Null
        $Window.SetAttribute("Title", $Config["Global"]["Title"]) | Out-Null
        $Window.SetAttribute("Width", $Config["Global"]["Width"]) | Out-Null
        $Window.SetAttribute("Height", $Config["Global"]["Height"]) | Out-Null
        $Window.SetAttribute("ResizeMode", $Config["Global"]["Resize"]) | Out-Null
        $MainGrid = $Form.CreateElement("Grid")
        $TabControl = $Form.CreateElement("TabControl")
        # Tab management
        Foreach ( $Tab in $Config.Keys ) {
            # Skip configuration part
            if ( $Tab -eq "Global" ) { Continue }
            $TabItem = $Form.CreateElement("TabItem")
            $TabItemHeader = $Form.CreateElement("TabItem.Header")
            $StackPanel = $Form.CreateElement("StackPanel")
            $StackPanel.SetAttribute("Orientation", "Vertical") | Out-Null
            # Get tab information
            $TabName, $TabColor = $Tab.Split(";")
            if ( $TabColor -eq $null ) { $TabColor = "Black" }
            $TextBlock = $Form.CreateElement("TextBlock")
            $TextBlock.SetAttribute("Text", $TabName) | Out-Null
            $TextBlock.SetAttribute("Foreground", $TabColor) | Out-Null
            $TextBlock.SetAttribute("FontWeight", "Bold") | Out-Null
            $Grid = $Form.CreateElement("Grid")
            $GridColumnDefinitions = $Form.CreateElement("Grid.ColumnDefinitions")
            for ( $i = 0; $i -le (2*$Config["Global"]["Rows"]-1); $i++ ) {
                $ColumnDefinition = $Form.CreateElement("ColumnDefinition")
                $ColumnDefinition.SetAttribute("Width", @("5", "1*")[($i % 2 -eq 0)]) | Out-Null
                $GridColumnDefinitions.AppendChild($ColumnDefinition) | Out-Null
            }
            $GridRowDefinitions = $Form.CreateElement("Grid.RowDefinitions")
            for ( $i = 0; $i -le (2*$Config["Global"]["Rows"]-1); $i++ ) {
                $RowDefinition = $Form.CreateElement("RowDefinition")
                $RowDefinition.SetAttribute("Height", @("5", "1*")[($i % 2 -eq 0)]) | Out-Null
                $GridRowDefinitions.AppendChild($RowDefinition) | Out-Null
            }
            $Grid.AppendChild($GridColumnDefinitions) | Out-Null
            $Grid.AppendChild($GridRowDefinitions) | Out-Null
        
            # Content management
            Foreach ( $Key in $Config[$Tab].Keys ) {
                Foreach ( $Value in $Config[$Tab][$Key] ) {
                    # Column and row span management
                    $ButtonLabel, $ButtonColumnSpan, $ButtonRowSpan = $Key.Split(";")
                    $ButtonColumn, $ButtonRow, $ButtonScript = $Value.Split(";")
                    #$ButtonScript = [array](escapeDoubleQuote @($ButtonScript))
                    $ButtonScript = [array](ReplaceInArray @($ButtonScript) "`$HOME" (Split-Path -Path $ConfigComputedPath -Parent))
                    $ButtonScript = [array](@($ButtonScript))
                    $Button = $Form.CreateElement("Button")
                    $Button.SetAttribute("Grid.Column", 2*$ButtonColumn) | Out-Null
                    $Button.SetAttribute("Grid.Row", 2*$ButtonRow) | Out-Null
                    $Button.SetAttribute("x:Name", "ID$GlobalID") | Out-Null
                    $Button.InnerText = $ButtonLabel
                    if ( -not ($ButtonColumnSpan -eq $null) ) {
                        $Button.SetAttribute("Grid.ColumnSpan", 2*$ButtonColumnSpan) | Out-Null
                    }
                    if ( -not ($ButtonRowSpan -eq $null) ) {
                        $Button.SetAttribute("Grid.RowSpan", 2*$ButtonRowSpan) | Out-Null
                    }
                    $ButtonContentTemplate = $Form.CreateElement("Button.ContentTemplate")
                    # Manage onClick scripts in a separate hashmap to avoid looping on all INI again
                    $OnClickScripts["ID$GlobalID"] = $ButtonScript
                    $GlobalID += 1
                    $Grid.AppendChild($Button) | Out-Null
                }
            } 
            $StackPanel.AppendChild($TextBlock) | Out-Null
            $TabItemHeader.AppendChild($StackPanel) | Out-Null
            $TabItem.AppendChild($TabItemHeader) | Out-Null
            $TabItem.AppendChild($Grid) | Out-Null
            $TabControl.AppendChild($TabItem) | Out-Null
        }
        $MainGrid.AppendChild($TabControl) | Out-Null
        $Window.AppendChild($MainGrid) | Out-Null
        $Form.AppendChild($Window) | Out-Null
        #Create a form
        $XMLReader = (New-Object System.Xml.XmlNodeReader ([xml]$Form.InnerXML))
        $XMLForm = [Windows.Markup.XamlReader]::Load($XMLReader)
        # Onclick management
        Foreach ( $Key in $OnClickScripts.Keys ) {
            $Button = $XMLForm.FindName($Key)
            $Button.Tag = @{Script=$($OnClickScripts[$Key])}
            $DynamicScript = {
                param($Sender)
                foreach ( $Script in $($Sender.Tag.Script) ) {
                    Start-Process 'cmd' -WindowStyle Hidden -Verb RunAs -ArgumentList "/c $Script"
                }
            }
            $Button.Add_click($DynamicScript)
        }
        #Show XMLform
        $XMLForm.ShowDialog()
    }