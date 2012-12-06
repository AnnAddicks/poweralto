Import-module ipv4math

function Find-PaAddressObject {
	<#
	.SYNOPSIS
		Search Object values for a given IP or FQDN
	.DESCRIPTION
		Returns objects from Palo Alto firewall.  If no objectname is specfied, all objects of the specified type are returned.  if -Exact is not used, an inclusive search of the specified ObjectName will be performed.
	.EXAMPLE
        Needs to write some examples
	.EXAMPLE
		Needs to write some examples
	.PARAMETER PaConnectionString
		Specificies the Palo Alto connection string with address and apikey.
    .PARAMETER ObjectType
		Specifies the type of objects to return.  Supports address, addressgroup, service, servicegroup
    .PARAMETER ObjectName
        Declares a specific object to return.
    .PARAMETER Exact
        Specifies that only an exact name match should be returned.  No inclusive search is performed.
	#>
    
    Param (
        [Parameter(ParameterSetName="config",Mandatory=$True,Position=0)]
        [ValidatePattern("(\w+\.)+\w+(\/\d{2})?")]
        [String]$SearchString,

        [Parameter(Mandatory=$False)]
        [alias('pc')]
        [String]$PaConnection
    )

    BEGIN {
        $AddressObject = @{}
        $AddressProperties = @("Name","Type","Value")
        foreach ($Value in $AddressProperties) {
            $AddressObject.Add($Value,$null)
        }
        
        $ReturnObject = @{}
        $ReturnProperties = @("Groups","Addresses")
        foreach ($Value in $ReturnProperties) {
            $ReturnObject.Add($Value,$null)
        }
        
        Function Process-Query ( [String]$PaConnectionString ) {
            $AddressObjects = @()
            $GroupObjects = @()
            $Addresses = (Send-PaApiQuery -Config get -xpath "/config/devices/entry/vsys/entry/address" -pc $PaConnectionString).response.result.address.entry
            $AddressGroups = (Send-PaApiQuery -Config get -xpath "/config/devices/entry/vsys/entry/address-group"-pc $PaConnectionString).response.result."address-group".entry
            $Found = @()
            foreach ($Address in $Addresses) {
                $IsFound = $false
                $SearchArray = @()
                $CurrentAddress = New-Object PsObject -Property $AddressObject
                $CurrentAddress.Name = $Address.Name
                if ($Address."ip-netmask") {
                    $CurrentAddress.Type = "ip-netmask"
                    if ($Address."ip-netmask"."#text") {
                        $CurrentAddress.Value = $Address."ip-netmask"."#text"
                    } else {
                        $CurrentAddress.Value = $Address."ip-netmask"
                    }
                    if ($CurrentAddress.Value -match "/") {
                        $AddressSplit = $CurrentAddress.Value.Split("/")
                        $AddressOnly = $AddressSplit[0]
                        $Mask = $AddressSplit[1]
                        if ($Mask -eq 32) {
                            $IsFound = ($AddressOnly -eq $SearchString)
                        } else {
                            $Start = Get-NetworkAddress $AddressOnly (ConvertTo-Mask $Mask)
                            $Stop = Get-BroadcastAddress $AddressOnly (ConvertTo-Mask $Mask)
                            $IsFound = Test-IpRange "$start-$stop" $SearchString
                        }
                    } else {
                        $IsFound = ($CurrentAddress.Value -eq $SearchString)
                    }
                } elseif ($Address."ip-range") {
                    $CurrentAddress.Type = "ip-range"
                    $CurrentAddress.Value = $Address."ip-range"
                    $IsFound = Test-IpRange $CurrentAddress.value $SearchString
                } elseif ($Address.fqdn) {
                    $CurrentAddress.Type = "fqdn"
                    $CurrentAddress.Value = $Address.fqdn
                    $IsFound = ($CurrentAddress.Value -eq $SearchString)
                }
                if ($IsFound) {
                    $AddressObjects += $CurrentAddress
                }
            }
            $ReturnObject.Addresses = $AddressObjects

            foreach ($Group in $AddressGroups) {
                foreach ($Address in $AddressObjects) {
                    if (($Group.Member -contains $Address.Name) -or ($Group.Member."#text" -contains $Address.Name)) {
                        $GroupObjects += $Group
                    }
                }
            }
            $ReturnObject.Groups = $GroupObjects

            return $ReturnObject
        }
    }

    PROCESS {
        if ($PaConnection) {
            Process-Query $PaConnection
        } else {
            if (Test-PaConnection) {
                foreach ($Connection in $Global:PaConnectionArray) {
                    Process-Query $Connection.ConnectionString
                }
            } else {
                Throw "No Connections"
            }
        }
    }
}
function Get-PaConnectionString {
	<#
	.SYNOPSIS
		Connects to a Palo Alto firewall and returns an connection string with API key.
	.DESCRIPTION
		Connects to a Palo Alto firewall and returns an connection string with API key.
	.EXAMPLE
		C:\PS> Connect-Pa -Address 192.168.1.1 -Cred $PSCredential
        https://192.168.1.1/api/?key=LUFRPT1SanJaQVpiNEg4TnBkNGVpTmRpZTRIamR4OUE9Q2lMTUJGREJXOCs3SjBTbzEyVSt6UT01
	.EXAMPLE
		C:\PS> Connect-Pa 192.168.1.1
        https://192.168.1.1/api/?key=LUFRPT1SanJaQVpiNEg4TnBkNGVpTmRpZTRIamR4OUE9Q2lMTUJGREJXOCs3SjBTbzEyVSt6UT01
	.PARAMETER Address
		Specifies the IP or DNS name of the system to connect to.
    .PARAMETER Credential
        If no credential object is specified, the user will be prompted.
    .OUTPUTS
        System.String
	#>

    Param (
        [Parameter(Mandatory=$True,Position=0)]
        [string]$Address,

        [Parameter(Mandatory=$True,Position=1)]
        [System.Management.Automation.PSCredential]$Cred
    )

    BEGIN {
        $WebClient = New-Object System.Net.WebClient
        [Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
        Add-Type -AssemblyName System.Management.Automation

        $global:PaConnectionArray = @()
        $Connection = @{}
        $ConnectionProps = @("Address","ApiKey","ConnectionString")
        foreach ($Value in $ConnectionProps) {
            $Connection.Add($Value,$null)
        }
    }

    PROCESS {
        $user = $cred.UserName.Replace("\","")
        $ApiKey = ([xml]$WebClient.DownloadString("https://$Address/api/?type=keygen&user=$user&password=$($cred.getnetworkcredential().password)"))
        if ($ApiKey.response.status -eq "success") {
            $CurrentConnection = New-Object PsObject -Property $Connection
            $CurrentConnection.Address = $Address
            $CurrentConnection.ApiKey = $ApiKey.response.result.key
            $CurrentConnection.ConnectionString = "https://$Address/api/?key=$($ApiKey.response.result.key)"
            #$CurrentConnection
            $global:PaConnectionArray += $CurrentConnection
            return "https://$Address/api/?key=$($ApiKey.response.result.key)"
        } else {
            Throw "$($ApiKey.response.result.msg)"
        }
    }
}

function Get-PaNatRule {
    <#
	.SYNOPSIS
		Returns Security Ruleset from Palo Alto firewall.
	.DESCRIPTION
		Returns Security Ruleset from Palo Alto firewall.
	.EXAMPLE
        EXAMPLES!
	.EXAMPLE
		EXAMPLES!
	.PARAMETER PaConnectionString
		Specificies the Palo Alto connection string with address and apikey.
	#>

    Param (
        [Parameter(Mandatory=$False)]
        [alias('pc')]
        [String]$PaConnection
    )

    BEGIN {
        $xpath = "/config/devices/entry/vsys/entry/rulebase/nat/rules"
        function Text-Query ( [String]$PaProp ) {
            if ($entry."$PaProp"."#text") { return $entry."$PaProp"."#text" } `
                else { return  $entry."$PaProp" }
        }
        function Member-Query ( [String]$PaProp ) {
            if ($entry."$PaProp".member."#text") { return $entry."$PaProp".member."#text" } `
                else { return  $entry."$PaProp".member }
        }
        Function Process-Query ( [String]$PaConnectionString ) {
            $NatRule = @{}
            $ExportString = @("Name","Description","Tag","SourceZone","DestinationZone","DestinationInterface","Service","SourceAddress","DestinationAddress","SourceTransType","SourceTransAddressType","SourceTransInterface","SourceTransAddress","BiDirectional","DestTransEnabled","DestTransAddress","DestTransPort")
            foreach ($Value in $ExportString) {
                $NatRule.Add($Value,$null)
            }
            $NatRules = @()
            $NatRulebase = (Send-PaApiQuery -Config get -XPath $xpath -pc $PaConnectionString).response.result.rules.entry
            
            #Covert results into PSobject
            foreach ($entry in $NatRulebase) {
                $CurrentRule = New-Object PSObject -Property $NatRule

                $CurrentRule.Name                   = $entry.Name
                $CurrentRule.Description            = $entry.Description
                $CurrentRule.Tag                    = Member-Query "tag"
                $CurrentRule.SourceZone             = Member-Query "from"
                $CurrentRule.DestinationZone        = Member-Query "to"
                $CurrentRule.DestinationInterface   = Text-Query "to-interface"
                $CurrentRule.Service                = Text-Query "service"
                $CurrentRule.SourceAddress          = Member-Query "source"
                $CurrentRule.DestinationAddress     = Member-Query "destination"
                if ($entry."source-translation"."dynamic-ip-and-port") {
                    $CurrentRule.SourceTransType    = "DynamicIpAndPort"
                    if ($entry."source-translation"."dynamic-ip-and-port"."interface-address".interface."#text") {
                        $CurrentRule.SourceTransAddressType = "InterfaceAddress"
                        $CurrentRule.SourceTransInterface = $entry."source-translation"."dynamic-ip-and-port"."interface-address".interface."#text"
                        $CurrentRule.SourceTransAddress = $entry."source-translation"."dynamic-ip-and-port"."interface-address".ip."#text"
                    } elseif ($entry."source-translation"."dynamic-ip-and-port"."interface-address".interface) {
                        $CurrentRule.SourceTransAddressType = "InterfaceAddress"
                        $CurrentRule.SourceTransInterface = $entry."source-translation"."dynamic-ip-and-port"."interface-address".interface
                    } elseif ($entry."source-translation"."dynamic-ip-and-port"."translated-address") {
                        $CurrentRule.SourceTransAddressType = "TranslatedAddress"
                        $CurrentRule.SourceTransInterface = $entry."source-translation"."dynamic-ip-and-port"."translated-address".member."#text"
                    }
                } elseif ($entry."source-translation"."static-ip") {
                    $CurrentRule.SourceTransType    = "StaticIp"
                    $CurrentRule.SourceTransAddress = $entry."source-translation"."static-ip"."translated-address"."#text"
                    $CurrentRule.BiDirectional      = $entry."source-translation"."static-ip"."bi-directional"."#text"
                } elseif ($entry."source-translation"."dynamic-ip") {
                    $CurrentRule.SourceTransType = "DynamicIp"
                    $CurrentRule.SourceTransAddress = $entry."source-translation"."dynamic-ip"."translated-address".member."#text"
                }
                if ($entry."destination-translation") {
                    $CurrentRule.DestTransEnabled = "yes"
                    $CurrentRule.DestTransAddress = $entry."destination-translation"."translated-address"."#text"
                    $CurrentRule.DestTransPort    = $entry."destination-translation"."translated-port"."#text"
                }
                $NatRules += $CurrentRule
            }
            return $NatRules | select $ExportString
        }
    }

    PROCESS {
        if ($PaConnection) {
            Process-Query $PaConnection
        } else {
            if (Test-PaConnection) {
                foreach ($Connection in $Global:PaConnectionArray) {
                    Process-Query $Connection.ConnectionString
                }
            } else {
                Throw "No Connections"
            }
        }
    }
}

function Get-PaSecurityRule {
    <#
	.SYNOPSIS
		Returns Security Ruleset from Palo Alto firewall.
	.DESCRIPTION
		Returns Security Ruleset from Palo Alto firewall.
	.EXAMPLE
        EXAMPLES!
	.EXAMPLE
		EXAMPLES!
	.PARAMETER PaConnectionString
		Specificies the Palo Alto connection string with address and apikey.
	#>

    Param (
        [Parameter(Mandatory=$False)]
        [alias('pc')]
        [String]$PaConnection
    )

    BEGIN {
        $xpath = "/config/devices/entry/vsys/entry/rulebase/security/rules"
        Function Process-Query ( [String]$PaConnectionString ) {
            $SecurityRule = @{}
            $ExportString = @("Name","Description","Tag","SourceZone","SourceAddress","SourceNegate","SourceUser","HipProfile","DestinationZone","DestinationAddress","DestinationNegate","Application","Service","UrlCategory","Action","ProfileType","ProfileGroup","ProfileVirus","ProfileVuln","ProfileSpy","ProfileUrl","ProfileFile","ProfileData","LogStart","LogEnd","LogForward","DisableSRI","Schedule","QosType","QosMarking","Disabled")
            foreach ($Value in $ExportString) {
                $SecurityRule.Add($Value,$null)
            }
            $SecurityRules = @()
            $SecurityRulebase = (Send-PaApiQuery -Config show -XPath $xpath -pc $PaConnectionString).response.result.rules.entry
            
            #Covert results into PSobject
            foreach ($entry in $SecurityRulebase) {
                $CurrentRule = New-Object PSObject -Property $SecurityRule
                    $CurrentRule.Name               = $entry.name
                    $CurrentRule.Description        = $entry.description
                    $CurrentRule.Tag                = $entry.tag.member
                    $CurrentRule.SourceZone         = $entry.from.member
                    $CurrentRule.SourceAddress      = $entry.source.member
                    $CurrentRule.SourceNegate       = $entry."negate-source"
                    $CurrentRule.SourceUser         = $entry."source-user".member
                    $CurrentRule.HipProfile         = $entry."hip-profiles".member
                    $CurrentRule.DestinationZone    = $entry.to.member
                    $CurrentRule.DestinationAddress = $entry.destination.member
                    $CurrentRule.DestinationNegate  = $entry."negate-destination"
                    $CurrentRule.Application        = $entry.application.member
                    $CurrentRule.Service            = $entry.service.member
                    $CurrentRule.UrlCategory        = $entry.category.member
                    $CurrentRule.Action             = $entry.action
                    if ($entry."profile-setting".group) {
                        $CurrentRule.ProfileGroup   = $entry."profile-setting".group.member
                        $CurrentRule.ProfileType    = "group"
                    } elseif ($entry."profile-setting".profiles) {
                        $CurrentRule.ProfileType    = "profiles"
                        $CurrentRule.ProfileVirus   = $entry."profile-setting".profiles.virus.member
                        $CurrentRule.ProfileVuln    = $entry."profile-setting".profiles.vulnerability.member
                        $CurrentRule.ProfileSpy     = $entry."profile-setting".profiles.spyware.member
                        $CurrentRule.ProfileUrl     = $entry."profile-setting".profiles."url-filtering".member
                        $CurrentRule.ProfileFile    = $entry."profile-setting".profiles."file-blocking".member
                        $CurrentRule.ProfileData    = $entry."profile-setting".profiles."data-filtering".member
                    }
                    $CurrentRule.LogStart           = $entry."log-start"
                    $CurrentRule.LogEnd             = $entry."log-end"
                    $CurrentRule.LogForward         = $entry."log-setting"
                    $CurrentRule.Schedule           = $entry.schedule
                    if ($entry.qos.marking."ip-dscp") {
                        $CurrentRule.QosType        = "ip-dscp"
                        $CurrentRule.QosMarking     = $entry.qos.marking."ip-dscp"
                    } elseif ($entry.qos.marking."ip-precedence") {
                        $CurrentRule.QosType        = "ip-precedence"
                        $CurrentRule.QosMarking     = $entry.qos.marking."ip-precedence"
                    }
                    $CurrentRule.DisableSRI         = $entry.option."disable-server-response-inspection"
                    $CurrentRule.Disabled           = $entry.disabled
                $SecurityRules += $CurrentRule
            }
            #$SecurityRulebase
            return $SecurityRules | select $ExportString
        }
    }

    PROCESS {
        if ($PaConnection) {
            Process-Query $PaConnection
        } else {
            if (Test-PaConnection) {
                foreach ($Connection in $Global:PaConnectionArray) {
                    Process-Query $Connection.ConnectionString
                }
            } else {
                Throw "No Connections"
            }
        }
    }
}

function Get-PaSystemInfo {
	<#
	.SYNOPSIS
		Returns the version number of various components of a Palo Alto firewall.
	.DESCRIPTION
		Returns the version number of various components of a Palo Alto firewall.
	.EXAMPLE
        C:\PS> Get-PaVersion -PaConnectionString https://192.168.1.1/api/?key=apikey
        hostname                              : pegasus
        ip-address                            : 192.168.1.1
        netmask                               : 255.255.255.0
        default-gateway                       : 192.168.1.10
        ipv6-address                          : 
        ipv6-link-local-address               : fe80::b60c:23ff:fe0c:5500/64
        ipv6-default-gateway                  : 
        mac-address                           : b4:0c:25:03:55:00
        time                                  : Mon Nov 19 17:02:19 2012
                                        
        uptime                                : 2 days, 15:26:48
        devicename                            : pegasus
        family                                : 200
        model                                 : PA-200
        serial                                : 012345678901
        sw-version                            : 5.0.0
        global-protect-client-package-version : 1.2.0
        app-version                           : 338-1582
        app-release-date                      : 2012/11/13  12:46:13
        av-version                            : 882-1216
        av-release-date                       : 2012/11/15  18:13:58
        threat-version                        : 338-1582
        threat-release-date                   : 2012/11/13  12:46:13
        wildfire-version                      : 0
        wildfire-release-date                 : unknown
        url-filtering-version                 : 3984
        global-protect-datafile-version       : 0
        global-protect-datafile-release-date  : unknown
        logdb-version                         : 5.0.2
        platform-family                       : 200
        logger_mode                           : False
        vpn-disable-mode                      : off
        operational-mode                      : normal
        multi-vsys                            : off
	.EXAMPLE
		C:\PS> Get-PaVersion https://192.168.1.1/api/?key=apikey
	.PARAMETER PaConnectionString
		Specificies the Palo Alto connection string with address and apikey.
	#>

    Param (
        [Parameter(Mandatory=$False)]
        [alias('pc')]
        [String]$PaConnection
    )

    BEGIN {
        $WebClient = New-Object System.Net.WebClient
        [Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
        Function Process-Query ( [String]$PaConnectionString ) {
            $SystemInfo = (Send-PaApiQuery -op "<show><system><info></info></system></show>").response.result.system
            return $SystemInfo
        }
    }

    PROCESS {
        if ($PaConnection) {
            Process-Query $PaConnection
        } else {
            if (Test-PaConnection) {
                foreach ($Connection in $Global:PaConnectionArray) {
                    Process-Query $Connection.ConnectionString
                }
            } else {
                Throw "No Connections"
            }
        }
    }
}

function Get-PaNatRule {
    <#
	.SYNOPSIS
		Returns Security Ruleset from Palo Alto firewall.
	.DESCRIPTION
		Returns Security Ruleset from Palo Alto firewall.
	.EXAMPLE
        EXAMPLES!
	.EXAMPLE
		EXAMPLES!
	.PARAMETER PaConnectionString
		Specificies the Palo Alto connection string with address and apikey.
	#>

    Param (
        [Parameter(Mandatory=$False)]
        [alias('pc')]
        [String]$PaConnection
    )

    BEGIN {
        $xpath = "/config/devices/entry/vsys/entry/rulebase/nat/rules"
        function Text-Query ( [String]$PaProp ) {
            if ($entry."$PaProp"."#text") { return $entry."$PaProp"."#text" } `
                else { return  $entry."$PaProp" }
        }
        function Member-Query ( [String]$PaProp ) {
            if ($entry."$PaProp".member."#text") { return $entry."$PaProp".member."#text" } `
                else { return  $entry."$PaProp".member }
        }
        Function Process-Query ( [String]$PaConnectionString ) {
            $NatRule = @{}
            $ExportString = @("Name","Description","Tag","SourceZone","DestinationZone","DestinationInterface","Service","SourceAddress","DestinationAddress","SourceTransType","SourceTransAddressType","SourceTransInterface","SourceTransAddress","BiDirectional","DestTransEnabled","DestTransAddress","DestTransPort")
            foreach ($Value in $ExportString) {
                $NatRule.Add($Value,$null)
            }
            $NatRules = @()
            $NatRulebase = (Send-PaApiQuery -Config get -XPath $xpath -pc $PaConnectionString).response.result.rules.entry
            
            #Covert results into PSobject
            foreach ($entry in $NatRulebase) {
                $CurrentRule = New-Object PSObject -Property $NatRule

                $CurrentRule.Name                   = $entry.Name
                $CurrentRule.Description            = $entry.Description
                $CurrentRule.Tag                    = Member-Query "tag"
                $CurrentRule.SourceZone             = Member-Query "from"
                $CurrentRule.DestinationZone        = Member-Query "to"
                $CurrentRule.DestinationInterface   = Text-Query "to-interface"
                $CurrentRule.Service                = Text-Query "service"
                $CurrentRule.SourceAddress          = Member-Query "source"
                $CurrentRule.DestinationAddress     = Member-Query "destination"
                if ($entry."source-translation"."dynamic-ip-and-port") {
                    $CurrentRule.SourceTransType    = "DynamicIpAndPort"
                    if ($entry."source-translation"."dynamic-ip-and-port"."interface-address".interface."#text") {
                        $CurrentRule.SourceTransAddressType = "InterfaceAddress"
                        $CurrentRule.SourceTransInterface = $entry."source-translation"."dynamic-ip-and-port"."interface-address".interface."#text"
                        $CurrentRule.SourceTransAddress = $entry."source-translation"."dynamic-ip-and-port"."interface-address".ip."#text"
                    } elseif ($entry."source-translation"."dynamic-ip-and-port"."interface-address".interface) {
                        $CurrentRule.SourceTransAddressType = "InterfaceAddress"
                        $CurrentRule.SourceTransInterface = $entry."source-translation"."dynamic-ip-and-port"."interface-address".interface
                    } elseif ($entry."source-translation"."dynamic-ip-and-port"."translated-address") {
                        $CurrentRule.SourceTransAddressType = "TranslatedAddress"
                        $CurrentRule.SourceTransInterface = $entry."source-translation"."dynamic-ip-and-port"."translated-address".member."#text"
                    }
                } elseif ($entry."source-translation"."static-ip") {
                    $CurrentRule.SourceTransType    = "StaticIp"
                    $CurrentRule.SourceTransAddress = $entry."source-translation"."static-ip"."translated-address"."#text"
                    $CurrentRule.BiDirectional      = $entry."source-translation"."static-ip"."bi-directional"."#text"
                } elseif ($entry."source-translation"."dynamic-ip") {
                    $CurrentRule.SourceTransType = "DynamicIp"
                    $CurrentRule.SourceTransAddress = $entry."source-translation"."dynamic-ip"."translated-address".member."#text"
                }
                if ($entry."destination-translation") {
                    $CurrentRule.DestTransEnabled = "yes"
                    $CurrentRule.DestTransAddress = $entry."destination-translation"."translated-address"."#text"
                    $CurrentRule.DestTransPort    = $entry."destination-translation"."translated-port"."#text"
                }
                $NatRules += $CurrentRule
            }
            return $NatRules | select $ExportString
        }
    }

    PROCESS {
        if ($PaConnection) {
            Process-Query $PaConnection
        } else {
            if (Test-PaConnection) {
                foreach ($Connection in $Global:PaConnectionArray) {
                    Process-Query $Connection.ConnectionString
                }
            } else {
                Throw "No Connections"
            }
        }
    }
}

function Invoke-PaCommit {
	<#
	.SYNOPSIS
		Commits candidate config to Palo Alto firewall
	.DESCRIPTION
		Commits candidate config to Palo Alto firewall and returns resulting job stats.
	.EXAMPLE
        Needs to write some examples
	.EXAMPLE
		Needs to write some examples
	.PARAMETER PaConnectionString
		Specificies the Palo Alto connection string with address and apikey.
    .PARAMETER Force
		Forces the commit command in the event of a conflict.
	#>
    
    Param (
        [Parameter(Mandatory=$False)]
        [alias('pc')]
        [String]$PaConnection,

        [Parameter(Mandatory=$False)]
        [switch]$Force
    )

    BEGIN {
        $WebClient = New-Object System.Net.WebClient
        [Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

        Function Process-Query ( [String]$PaConnectionString ) {
            if ($Force) {
                $CustomData = Send-PaApiQuery -commit -force
            } else {
                $CustomData = Send-PaApiQuery -commit
            }
            if ($CustomData.response.status -eq "success") {
                if ($CustomData.response.msg -match "no changes") {
                    Return "There are no changes to commit."
                }
                $job = $CustomData.response.result.job
                $cmd = "<show><jobs><id>$job</id></jobs></show>"
                $JobStatus = Send-PaApiQuery -op "$cmd"
                while ($JobStatus.response.result.job.status -ne "FIN") {
                    Write-Progress -Activity "Commiting to PA" -Status "$($JobStatus.response.result.job.progress)% complete"-PercentComplete ($JobStatus.response.result.job.progress)
                    $JobStatus = Send-PaApiQuery -op "$cmd"
                }
                return $JobStatus.response.result.job
            }
            Throw "$($CustomData.response.result.msg)"
        }
    }

    PROCESS {
        if ($PaConnection) {
            Process-Query $PaConnection
        } else {
            if (Test-PaConnection) {
                foreach ($Connection in $Global:PaConnectionArray) {
                    Process-Query $Connection.ConnectionString
                }
            } else {
                Throw "No Connections"
            }
        }

    }
}

function Send-PaApiQuery {
	<#
	.SYNOPSIS
		Query Palo Alto for custom data.
	.DESCRIPTION
		Query Palo Alto for custom data
	.EXAMPLE
        Needs to write some examples
	.EXAMPLE
		Needs to write some examples
	.PARAMETER PaConnectionString
		Specificies the Palo Alto connection string with address and apikey.
	#>
    Param (
        #############################CONFIG#############################

        [Parameter(ParameterSetName="config",Mandatory=$True,Position=0)]
        [ValidateSet("show","get","set","edit","delete","rename","clone","move")] 
        [String]$Config,

        [Parameter(ParameterSetName="config",Mandatory=$True,Position=2)]
        [ValidatePattern("\/config\/.*")]
        [String]$XPath,

        [Parameter(ParameterSetName="config")]
        [alias('e')]
        [String]$Element,

        [Parameter(ParameterSetName="config")]
        [alias('m')]
        [String]$Member,

        [Parameter(ParameterSetName="config")]
        [alias('nn')]
        [String]$NewName,

            #========================CLONE=========================#

        [Parameter(ParameterSetName="config")]
        [alias('cf')]
        [String]$CloneFrom,

            #=========================MOVE=========================#

        [Parameter(ParameterSetName="config")]
        [alias('mw')]
        [ValidateSet("after","before","top","bottom")] 
        [String]$MoveWhere,

        [Parameter(ParameterSetName="config")]
        [alias('dst')]
        [String]$MoveDestination,

        ###########################OPERATIONAL##########################

        [Parameter(ParameterSetName="op",Mandatory=$True,Position=0)]
        [ValidatePattern("<\w+>.*<\/\w+>")]
        [String]$Op,

        #############################REPORT#############################

        [Parameter(ParameterSetName="report",Mandatory=$True,Position=0)]
        [ValidateSet("dynamic","predefined")]
        #No Custom Reports supported yet, should probably make a seperate cmdlet for it.
        [String]$Report,

        [Parameter(ParameterSetName="report")]
        [alias('rn')]
        [String]$ReportName,

        [Parameter(ParameterSetName="report")]
        [alias('r')]
        [Decimal]$Rows,

        [Parameter(ParameterSetName="report")]
        [alias('p')]
        [ValidateSet("last-60-seconds","last-15-minutes","last-hour","last-12-hrs","last-24-hrs","last-calendar-day","last-7-days","last-7-calendar-days","last-calendar-week","last-30-days")] 
        [String]$Period,

        [Parameter(ParameterSetName="report")]
        [alias('start')]
        [ValidatePattern("\d{4}\/\d{2}\/\d{2}\+\d{2}:\d{2}:\d{2}")]
        [String]$StartTime,

        [Parameter(ParameterSetName="report")]
        [alias('end')]
        [ValidatePattern("\d{4}\/\d{2}\/\d{2}\+\d{2}:\d{2}:\d{2}")]
        [String]$EndTime,

        #############################EXPORT#############################

        [Parameter(ParameterSetName="export",Mandatory=$True,Position=0)]
        [ValidateSet("application-pcap","threat-pcap","filter-pcap","filters-pcap","configuration","certificate","high-availability-key","key-pair","application-block-page","captive-portal-text","file-block-continue-page","file-block-page","global-protect-portal-custom-help-page","global-protect-portal-custom-login-page","global-protect-portal-custom-welcome-page","ssl-cert-status-page","ssl-optout-text","url-block-page","url-coach-text","virus-block-page","tech-support","device-state")]
        [String]$Export,

        [Parameter(ParameterSetName="export")]
        [alias('f')]
        [String]$From,

        [Parameter(ParameterSetName="export")]
        [alias('t')]
        [String]$To,

            #=========================DLP=========================#

        [Parameter(ParameterSetName="export")]
        [alias('dp')]
        [String]$DlpPassword,

            #=====================CERTIFICATE=====================#

        [Parameter(ParameterSetName="export")]
        [alias('ecn')]
        [String]$CertificateName,

        [Parameter(ParameterSetName="export")]
        [alias('ecf')]
        [ValidateSet("pkcs12","pem")]
        [String]$CertificateFormat,

        [Parameter(ParameterSetName="export")]
        [alias('epp')]
        [String]$ExportPassPhrase,

            #=====================TECH SUPPORT====================#

        [Parameter(ParameterSetName="export")]
        [alias('ta')]
        [ValidateSet("status","get","finish")]
        [String]$TsAction,

        [Parameter(ParameterSetName="export")]
        [alias('j')]
        [Decimal]$Job,

        [Parameter(ParameterSetName="export",Mandatory=$True)]
        [alias('ef')]
        [String]$ExportFile,


        #############################IMPORT#############################

        [Parameter(ParameterSetName="import",Mandatory=$True,Position=0)]
        [ValidateSet("software","anti-virus","content","url-database","signed-url-database","license","configuration","certificate","high-availability-key","key-pair","application-block-page","captive-portal-text","file-block-continue-page","file-block-page","global-protect-portal-custom-help-page","global-protect-portal-custom-login-page","global-protect-portal-custom-welcome-page","ssl-cert-status-page","ssl-optout-text","url-block-page","url-coach-text","virus-block-page","global-protect-client","custom-logo")]
        [String]$Import,

        [Parameter(ParameterSetName="import",Mandatory=$True,Position=1)]
        [String]$ImportFile,

            #=====================CERTIFICATE=====================#

        [Parameter(ParameterSetName="import")]
        [alias('icn')]
        [String]$ImportCertificateName,

        [Parameter(ParameterSetName="import")]
        [alias('icf')]
        [ValidateSet("pkcs12","pem")]
        [String]$ImportCertificateFormat,

        [Parameter(ParameterSetName="import")]
        [alias('ipp')]
        [String]$ImportPassPhrase,

            #====================RESPONSE PAGES====================#

        [Parameter(ParameterSetName="import")]
        [alias('ip')]
        [String]$ImportProfile,

            #=====================CUSTOM LOGO======================#

        [Parameter(ParameterSetName="import")]
        [alias('wh')]
        [ValidateSet("login-screen","main-ui","pdf-report-footer","pdf-report-header")]
        [String]$ImportWhere,

        ##############################LOGS##############################

        [Parameter(ParameterSetName="log",Mandatory=$True,Position=0)]
        [ValidateSet("traffic","threat","config","system","hip-match")]
        [String]$Log,

        [Parameter(ParameterSetName="log")]
        [alias('q')]
        [String]$LogQuery,

        [Parameter(ParameterSetName="log")]
        [alias('nl')]
        [ValidateRange(1,5000)]
        [Decimal]$NumberLogs,

        [Parameter(ParameterSetName="log")]
        [alias('sl')]
        [String]$SkipLogs,

        [Parameter(ParameterSetName="log")]
        [alias('la')]
        [ValidateSet("get","finish")]
        [String]$LogAction,

        [Parameter(ParameterSetName="log")]
        [alias('lj')]
        [Decimal]$LogJob,

        #############################USER-ID############################

        [Parameter(ParameterSetName="userid",Mandatory=$True,Position=0)]
        [String]$UserId,

        #############################COMMIT#############################

        [Parameter(ParameterSetName="commit",Mandatory=$True,Position=0)]
        [Switch]$Commit,

        [Parameter(ParameterSetName="commit")]
        [Switch]$Force,

        [Parameter(ParameterSetName="commit")]
        [alias('part')]
        [String]$Partial,

        ############################CONNECTION##########################

        [Parameter(Mandatory=$False)]
        [alias('pc')]
        [String]$PaConnection
    )

    BEGIN {
        $WebClient = New-Object System.Net.WebClient
        [Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
        Function Process-Query ( [String]$PaConnectionString ) {
            $url = $PaConnectionString
            #############################CONFIG#############################
            if ($Config) {
                $ReturnType = "String"
                $url += "&type=config"
                $url += "&action=$Config"
                $url += "&xpath=$xpath"
                if (($Config -eq "set") -or ($Config -eq "edit")-or ($Config -eq "delete")) {
                    $url += "/$Element"
                    $Member = $Member.replace(" ",'%20')
                    if ($Member -match ",") {
                        foreach ($Value in $Member.split(',')) {
                            if ($Value) { $Members += "<member>$Value</member>" }
                        }
                        $Member = $Members
                    }
                    $url+= "&element=<$element>$Member</$element>"
                } elseif ($Config -eq "rename") {
                    $url += "&newname=$NewName"
                } elseif ($Config -eq "clone") {
                    $url += "/"
                    $url += "&from=$xpath/$CloneFrom"
                    $url += "&newname=$NewName"
                    return "Times out ungracefully as of 11/20/12 on 5.0.0"
                } elseif ($Config -eq "move") {
                    $url += "&where=$MoveWhere"
                    if ($MoveDestination) {
                        $url += "&dst=$MoveDestination"
                    }
                }
                $global:lasturl = $url
                $global:response = [xml]$WebClient.DownloadString($url)
                return $global:response

            ###########################OPERATIONAL##########################
            } elseif ($Op) {
                $ReturnType = "String"
                $url += "&type=op"
                $url += "&cmd=$Op"
                $global:lasturl = $url
                $global:response = [xml]$WebClient.DownloadString($url)
                return $global:response

            #############################REPORT#############################
            } elseif ($Report) {
                $ReturnType = "String"
                $url += "&type=report"
                $url += "&reporttype=$Report"
                if ($ReportName) { $url += "&reportname=$ReportName" }
                if ($Rows) { $url += "&topn=$Rows" }
                if ($Period) {
                    $url+= "&period=$Period"
                } elseif ($StartTime) {
                    $url += "&starttime=$StartTime"
                    if ($EndTime) { $url += "&starttime=$EndTime" }
                }
                return [xml]$WebClient.DownloadString($url)
        
            #############################EXPORT#############################
            } elseif ($Export) {
                if (($export -eq "filters-pcap") -or ($export -eq "filter-pcap")) {
                    return "Times out ungracefully as of 11/20/12 on 5.0.0"
                }
                $url += "&type=export"
                $url += "&category=$Export"
                if ($From) { $url += "&from=$From" }
                if ($To) { $url += "&to=$To" }
                if ($DlpPassword) { $url += "dlp-password=$DlpPassword" }
                if ($CertificateName) {
                    $url += "&certificate-name=$CertificateName"
                    $url += "&include-key=no"
                }
                if ($CertificateFormat) { $url += "&format=$CertificateFormat" }
                if ($ExportPassPhrase) {
                    $url += "&include-key=yes"
                    $url += "&passphrase=$ExportPassPhrase"
                }
                if ($TsAction) { $url += "&action=$TsAction" }
                if ($Job) { $url += "&job-id=$Job" }
                $WebClient.DownloadFile($url,$ExportFile)
                return "File downloaded to $ExportFile"

            #############################IMPORT#############################
            } elseif ($Import) {
                $url += "&type=import"
                $url += "&category=$Import"
                if ($ImportCertificateName) {
                    $url += "&certificate-name=$ImportCertificateName"
                    $url += "&format=$ImportCertificateFormat"
                    $url += "&passphrase=$ImportPassPhrase"
                }
                if ($ImportProfile) { $url += "&profile=$ImportProfile" }
                if ($ImportWhere) { $url += "&where=$ImportWhere" }
                return "Currently non-functional, not sure how to do this with webclient"


            ##############################LOGS##############################
            } elseif ($Log) {
                "type=log"
                "log-type=$Log"
                if ($LogQuery) { "query=$($LogQuery.Replace(" ",'%20'))" }
                if ($NumberLogs) { "nlogs=$NumberLogs" }
                if ($SkipLogs) { "skip=$SkipLogs" }
                if ($LogAction) {
                    "action=$LogAction"
                    "job-id=$LogJob"
                }
                return "Haven't gotten to this yet"

            #############################USER-ID############################
            } elseif ($UserId) {
                "type=user-id"
                "action=set"
                "file=$UserId"
                return "Haven't gotten to this yet"

            #############################COMMIT#############################
            } elseif ($Commit) {
                $url += "&type=commit"
                $url += "&cmd=<commit></commit>"
                $global:lasturl = $url
                $global:response = [xml]$WebClient.DownloadString($url)
                return $global:response
            }
        }
    }

    PROCESS {
        if ($PaConnection) {
            Process-Query $PaConnection
        } else {
            if (Test-PaConnection) {
                foreach ($Connection in $Global:PaConnectionArray) {
                    Process-Query $Connection.ConnectionString
                }
            } else {
                Throw "No Connections"
            }
        }
    }
}

function Set-PaSecurityRule {
	<#
	.SYNOPSIS
		Edits settings on a Palo Alto Security Rule
	.DESCRIPTION
		Edits settings on a Palo Alto Security Rule
	.EXAMPLE
        Needs to write some examples
	.EXAMPLE
		Needs to write some examples
	.PARAMETER PaConnectionString
		Specificies the Palo Alto connection string with address and apikey.
	#>
    
    Param (
        #[Parameter(Mandatory=$True,Position=0)]
        #[string]$PaConnectionString,

        [Parameter(Mandatory=$True,Position=0)]
        [string]$Name,

        [alias('r')]
        [string]$Rename,

        [alias('d')]
        [string]$Description,

        [alias('t')]
        [string]$Tag,

        [alias('sz')]
        [string]$SourceZone,

        [alias('sa')]
        [string]$SourceAddress,

        [alias('su')]
        [string]$SourceUser,

        [alias('h')]
        [string]$HipProfile,

        [alias('dz')]
        [string]$DestinationZone,

        [alias('da')]
        [string]$DestinationAddress,

        [alias('app')]
        [string]$Application,

        [alias('s')]
        [string]$Service,

        [alias('u')]
        [string]$UrlCategory,

        [alias('sn')]
        [ValidateSet("yes","no")]
        [string]$SourceNegate,

        [alias('dn')]
        [ValidateSet("yes","no")] 
        [string]$DestinationNegate,

        [alias('a')]
        [ValidateSet("allow","deny")] 
        [string]$Action,

        [alias('ls')]
        [ValidateSet("yes","no")] 
        [string]$LogStart,

        [alias('le')]
        [ValidateSet("yes","no")] 
        [string]$LogEnd,

        [alias('lf')]
        [string]$LogForward,

        [alias('sc')]
        [string]$Schedule,

        [alias('dis')]
        [ValidateSet("yes","no")]
        [string]$Disabled,

        [alias('pg')]
        [string]$ProfileGroup,

        [alias('pvi')]
        [string]$ProfileVirus,

        [alias('pvu')]
        [string]$ProfileVuln,

        [alias('ps')]
        [string]$ProfileSpy,

        [alias('pu')]
        [string]$ProfileUrl,

        [alias('pf')]
        [string]$ProfileFile,

        [alias('pd')]
        [string]$ProfileData,

        [alias('qd')]
        [ValidateSet("none","af11","af12","af13","af21","af22","af23","af31","af32","af33","af41","af42","af43","cs0","cs1","cs2","cs3","cs4","cs5","cs6","cs7","ef")] 
        [string]$QosDscp,

        [alias('qp')]
        [ValidateSet("none","cs0","cs1","cs2","cs3","cs4","cs5","cs6","cs7")] 
        [string]$QosPrecedence,

        [alias('ds')]
        [ValidateSet("yes","no")] 
        [string]$DisableSri,

        [Parameter(Mandatory=$False)]
        [alias('pc')]
        [String]$PaConnection
    )

    BEGIN {
        $WebClient = New-Object System.Net.WebClient
        [Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

        function EditProperty ($parameter,$element,$xpath) {
            if ($parameter) {
                if ($parameter -eq "none") { $action = "delete" } `
                    else                   { $action = "edit" }
                $Response = Send-PaApiQuery -Config $action -XPath $xpath -Element $element -Member $parameter
                if ($Response.response.status -eq "success") {
                    return "$element`: success"
                } else {
                    throw $Response.response.msg.line
                }
            }
        }
        Function Process-Query ( [String]$PaConnectionString ) {
            $xpath = "/config/devices/entry/vsys/entry/rulebase/security/rules/entry[@name='$Name']"
            
            if ($Rename) {
                $Response = Send-PaApiQuery -Config rename -XPath $xpath -NewName $Rename -PaConnection $PaConnectionString
                if ($Response.response.status -eq "success") {
                    return "Rename success"
                } else {
                    throw $Response.response.msg.line
                }
            }

            EditProperty $Description "description" $xpath
            EditProperty $SourceNegate "negate-source" $xpath
            EditProperty $DestinationNegate "negate-destination" $xpath
            EditProperty $Action "action" $xpath
            EditProperty $LogStart "log-start" $xpath
            EditProperty $LogEnd "log-end" $xpath
            EditProperty $LogForward "log-setting" $xpath
            EditProperty $Schedule "schedule" $xpath
            EditProperty $Disabled "disabled" $xpath
            EditProperty $QosDscp "ip-dscp" "$xpath/qos/marking"
            EditProperty $QosPrecedence "ip-precedence" "$xpath/qos/marking"
            EditProperty $DisableSri "disable-server-response-inspection" "$xpath/option"
            EditProperty $SourceAddress "source" $xpath
            EditProperty $SourceZone "from" $xpath
            EditProperty $Tag "tag" $xpath
            EditProperty $SourceUser "source-user" $xpath
            EditProperty $HipProfile "hip-profiles" $xpath
            EditProperty $DestinationZone "to" $xpath
            EditProperty $DestinationAddress "destination" $xpath
            EditProperty $Application "application" $xpath
            EditProperty $Service "service" $xpath
            EditProperty $UrlCategory "category" $xpath
            EditProperty $HipProfile "hip-profiles" $xpath
            EditProperty $ProfileGroup "group" "$xpath/profile-setting"
            EditProperty $ProfileVirus "virus" "$xpath/profile-setting/profiles"
            EditProperty $ProfileVuln "vulnerability" "$xpath/profile-setting/profiles"
            EditProperty $ProfileSpy "spyware" "$xpath/profile-setting/profiles"
            EditProperty $ProfileUrl "url-filtering" "$xpath/profile-setting/profiles"
            EditProperty $ProfileFile "file-blocking" "$xpath/profile-setting/profiles"
            EditProperty $ProfileData "data-filtering" "$xpath/profile-setting/profiles"
        }
    }

    PROCESS {
        if ($PaConnection) {
            Process-Query $PaConnection
        } else {
            if (Test-PaConnection) {
                foreach ($Connection in $Global:PaConnectionArray) {
                    Process-Query $Connection.ConnectionString
                }
            } else {
                Throw "No Connections"
            }
        }
        
    }
}

function Test-PaConnection {
    if (!($Global:PaConnectionArray)) {
        return $false
    } else {
        return $true
    }
}

