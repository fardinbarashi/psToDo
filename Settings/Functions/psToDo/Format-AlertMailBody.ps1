function Format-AlertMailBody {
    <#
        Tables and inline styles only: Outlook for Windows renders HTML with the
        Word engine and ignores flexbox and grid.
        Every value from the JSON goes through HtmlEncode - a stray & or < in a
        description would otherwise break the layout.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Alert)

    $p   = Get-AlertPresentation -Alert $Alert
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

    $facts = [ordered]@{
        'Server'      = $Alert.servername
        'Template'    = $Alert.template
        'Environment' = $Alert.environment
        'Expires'     = $p.ExpireText
        'Days left'   = $Alert.daysLeft
        'Trigger'     = $p.TriggerText
    }

    $rows = foreach ($k in $facts.Keys) {
        "<tr><td style='padding:6px 20px 6px 0;color:#666;white-space:nowrap'>$k</td>" +
        "<td style='padding:6px 0'><b>$(& $enc $facts[$k])</b></td></tr>"
    }

    @"
<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222;max-width:640px">
  <div style="border-left:4px solid $($p.Color);padding-left:14px;margin-bottom:20px">
    <div style="font-size:12px;letter-spacing:.04em;color:$($p.Color)">$($Alert.urgency.ToUpper())</div>
    <div style="font-size:18px;font-weight:600">$(& $enc $p.Headline)</div>
  </div>

  <p style="margin:0 0 18px">$(& $enc $Alert.mailBody)</p>

  <table style="border-collapse:collapse">$($rows -join '')</table>

  <div style="margin-top:20px;padding:14px;background:#f3f3f3;border-radius:4px">
    <b>Action required</b><br>$(& $enc $Alert.action)
  </div>

  <p style="margin-top:20px;color:#888;font-size:12px">
    Sent by psToDo &middot; object $(& $enc $Alert.id) &middot; $(& $enc $p.TriggerText)
  </p>
</div>
"@
}