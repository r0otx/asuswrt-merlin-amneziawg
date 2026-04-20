<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <meta http-equiv="X-UA-Compatible" content="IE=Edge"/>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
  <meta http-equiv="Pragma" content="no-cache"/>
  <meta http-equiv="Expires" content="-1"/>
  <meta name="version" content="0.0.0-dev">
  <title>Asuswrt-Merlin — AmneziaWG</title>
  <link rel="stylesheet" type="text/css" href="/index_style.css">
  <link rel="stylesheet" type="text/css" href="/form_style.css">
  <link rel="stylesheet" type="text/css" href="/user/amneziawg.css">
  <script type="text/javascript" src="/state.js"></script>
  <script type="text/javascript" src="/popup.js"></script>
  <script type="text/javascript" src="/general.js"></script>
  <script type="text/javascript" src="/help.js"></script>
  <script type="text/javascript" src="/validator.js"></script>
  <script type="text/javascript" src="/httpApi.js"></script>
  <script type="text/javascript">
    // Initial state injected from custom_settings.txt
    window._customSettingsInline = <% get_custom_settings(); %>;
  </script>
</head>
<body onload="show_menu();">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<div id="hiddenMask" class="popup_bg" style="z-index:999;">
  <table cellpadding="5" cellspacing="0" id="dr_sweet_advise" class="dr_sweet_advise" align="center">
    <tr><td><img src="/images/loading.gif"></td>
        <td style="color:#FFFFFF;"><div id="drword" style="height:100%;"></div></td></tr>
  </table>
</div>
<table class="content" align="center" cellpadding="0" cellspacing="0">
<tr><td width="17">&nbsp;</td>
<td valign="top" width="202">
  <div id="mainMenu"></div>
  <div id="subMenu"></div>
</td>
<td valign="top">
  <div id="tabMenu" class="submenuBlock"></div>
  <table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
    <tr>
      <td align="left" valign="top">
        <table width="760px" border="0" cellpadding="5" cellspacing="0" bordercolor="#6b8fa3" class="FormTitle">
          <tr><td bgcolor="#4D595D" valign="top">
          <div>&nbsp;</div>
          <div class="formfonttitle">VPN — AmneziaWG</div>
          <div style="margin:10px 0 10px 5px;" class="splitLine"></div>
          <div class="formfontdesc">Amnezia-flavoured WireGuard VPN client with selective policy-based routing.</div>

          <!-- ============ Form ============ -->
          <form method="post" name="amneziawg_form" action="/start_apply.htm" target="hidden_frame"
                onsubmit="return false;">
          <input type="hidden" name="current_page" value="Advanced_AmneziaWG.asp">
          <input type="hidden" name="next_page" value="Advanced_AmneziaWG.asp">
          <input type="hidden" name="modified" value="0">
          <input type="hidden" name="flag" value="">
          <input type="hidden" id="action_script" name="action_script" value="start_awgsaveconf">
          <input type="hidden" name="action_wait" value="10">
          <input type="hidden" name="first_time" value="">
          <input type="hidden" id="amng_custom" name="amng_custom" value="">

          <!-- ============ Sticky status widget ============ -->
          <div id="awg-status-widget" class="awg-status-widget awg-state-stopped">
            <span>State:       <strong id="awg-status-state">stopped</strong></span>
            <span>Endpoint:    <strong id="awg-status-endpoint">—</strong></span>
            <span>Handshake:   <strong id="awg-status-handshake">never</strong></span>
            <span>RX / TX:     <strong id="awg-status-rxtx">0 B / 0 B</strong></span>
            <span id="awg-killswitch-badge" style="display:none"></span>
          </div>
          <div id="awg-conflict-banner" class="awg-conflict-banner" style="display:none">
            &#x26A0; Stock Merlin WG client is active — routing may conflict.
          </div>

          <!-- ============ Tunnel Configuration ============ -->
          <fieldset>
            <legend>Tunnel Configuration</legend>
            <p>
              <button type="button" class="form_button" onclick="AWG.import.openModal()">Import .conf</button>
            </p>
            <table class="FormTable" width="100%">
              <tr><th>Enabled</th>
                  <td><input type="checkbox" id="awg_enabled"></td></tr>
              <tr><th>Private Key</th>
                  <td><input type="text" id="awg_privatekey" class="form_input" maxlength="44" size="48"></td></tr>
              <tr><th>Address</th>
                  <td><input type="text" id="awg_address" class="form_input" size="24" placeholder="10.8.0.2/24"></td></tr>
              <tr><th>DNS</th>
                  <td><input type="text" id="awg_dns" class="form_input" size="32" placeholder="1.1.1.1"></td></tr>
              <tr><th>MTU</th>
                  <td><input type="text" id="awg_mtu" class="form_input" size="6" placeholder="1280"></td></tr>
              <tr><th>Jc</th><td><input type="text" id="awg_jc" class="form_input" size="6"></td></tr>
              <tr><th>Jmin</th><td><input type="text" id="awg_jmin" class="form_input" size="6"></td></tr>
              <tr><th>Jmax</th><td><input type="text" id="awg_jmax" class="form_input" size="6"></td></tr>
              <tr><th>S1</th><td><input type="text" id="awg_s1" class="form_input" size="6"></td></tr>
              <tr><th>S2</th><td><input type="text" id="awg_s2" class="form_input" size="6"></td></tr>
              <tr><th>S3</th><td><input type="text" id="awg_s3" class="form_input" size="6"></td></tr>
              <tr><th>S4</th><td><input type="text" id="awg_s4" class="form_input" size="6"></td></tr>
              <tr><th>H1</th><td><input type="text" id="awg_h1" class="form_input" size="24" placeholder="N or N-M"></td></tr>
              <tr><th>H2</th><td><input type="text" id="awg_h2" class="form_input" size="24"></td></tr>
              <tr><th>H3</th><td><input type="text" id="awg_h3" class="form_input" size="24"></td></tr>
              <tr><th>H4</th><td><input type="text" id="awg_h4" class="form_input" size="24"></td></tr>
              <tr><th>I1</th><td><input type="text" id="awg_i1" class="form_input" size="48" placeholder="&lt;b 0xabcd&gt;&lt;r 8&gt;&lt;t&gt;"></td></tr>
              <tr><th>I2</th><td><input type="text" id="awg_i2" class="form_input" size="48"></td></tr>
              <tr><th>I3</th><td><input type="text" id="awg_i3" class="form_input" size="48"></td></tr>
              <tr><th>I4</th><td><input type="text" id="awg_i4" class="form_input" size="48"></td></tr>
              <tr><th>I5</th><td><input type="text" id="awg_i5" class="form_input" size="48"></td></tr>
            </table>
          </fieldset>

          <!-- ============ Peer ============ -->
          <fieldset>
            <legend>Peer</legend>
            <table class="FormTable" width="100%">
              <tr><th>Public Key</th>
                  <td><input type="text" id="awg_peer_publickey" class="form_input" maxlength="44" size="48"></td></tr>
              <tr><th>Preshared Key (opt)</th>
                  <td><input type="text" id="awg_peer_presharedkey" class="form_input" maxlength="44" size="48"></td></tr>
              <tr><th>Endpoint</th>
                  <td><input type="text" id="awg_peer_endpoint" class="form_input" size="48" placeholder="vpn.example.com:51820"></td></tr>
              <tr><th>Allowed IPs</th>
                  <td><input type="text" id="awg_peer_allowed_ips" class="form_input" size="48" placeholder="0.0.0.0/0"></td></tr>
              <tr><th>Persistent Keepalive</th>
                  <td><input type="text" id="awg_peer_keepalive" class="form_input" size="6" placeholder="25"></td></tr>
            </table>
          </fieldset>

          <!-- ============ Policy-Based Routing ============ -->
          <fieldset>
            <legend>Policy-Based Routing</legend>
            <table class="FormTable" width="100%">
              <tr><th>Default Policy</th>
                  <td>
                    <select id="awg_default_policy" class="form_input">
                      <option value="direct">direct (not in VPN)</option>
                      <option value="vpn_all">vpn_all (whole LAN via VPN)</option>
                      <option value="vpn_geo">vpn_geo (only to geo IPs)</option>
                    </select>
                  </td></tr>
            </table>
            <p><strong>Devices</strong></p>
            <table id="awg-devices" class="FormTable" width="100%">
              <thead><tr><th>Name</th><th>IP</th><th>MAC</th><th>Policy</th><th></th></tr></thead>
              <tbody></tbody>
            </table>
            <p>
              From DHCP:
              <select id="awg-lease-picker" class="form_input">
                <option value="">— select lease —</option>
              </select>
              <button type="button" class="form_button" onclick="AWG.pbr.addFromLeasePicker()">Add from lease</button>
            </p>
            <p>
              Or manually:
              Name <input type="text" id="awg-manual-name" class="form_input" size="12">
              IP <input type="text" id="awg-manual-ip" class="form_input" size="14">
              MAC <input type="text" id="awg-manual-mac" class="form_input" size="18">
              <button type="button" class="form_button" onclick="AWG.pbr.addManual()">Add</button>
            </p>
            <table class="FormTable" width="100%">
              <tr><th>Geo Entries (CIDRs, comma-separated)</th>
                  <td><textarea id="awg_geo_entries" class="form_input" rows="3" cols="60"
                                placeholder="10.0.0.0/8, 1.2.3.4/32"></textarea></td></tr>
            </table>
          </fieldset>

          <!-- ============ Security ============ -->
          <fieldset>
            <legend>Security</legend>
            <table class="FormTable" width="100%">
              <tr><th>Strict Kill-switch</th>
                  <td><input type="checkbox" id="awg_killswitch_strict"> DROP all VPN traffic when tunnel is down</td></tr>
              <tr><th>Allow IPv6 Bypass</th>
                  <td><input type="checkbox" id="awg_ipv6_allow_bypass"> (disables IPv6 leak protection)</td></tr>
              <tr><th>DoH Blocklist (CIDRs)</th>
                  <td><textarea id="awg_doh_blocklist" class="form_input" rows="3" cols="60"
                                placeholder="1.1.1.1/32, 8.8.8.8/32 (optional)"></textarea></td></tr>
              <tr><th>UI Poll Interval (sec)</th>
                  <td><input type="text" id="awg_ui_poll_interval" class="form_input" size="6" placeholder="5"></td></tr>
            </table>
          </fieldset>

          <!-- ============ Daemon Log ============ -->
          <fieldset>
            <legend>Daemon Log (last 20 lines)</legend>
            <pre id="awg-log-tail" class="awg-log-tail">(no log entries)</pre>
          </fieldset>

          <!-- ============ Action buttons ============ -->
          <div class="awg-actions">
            <input type="button" class="button_gen" value="Save &amp; Apply" onclick="AWG.forms.submitSave()">
            <input type="button" class="button_gen" value="Start"   onclick="AWG.forms.submitControl('awgstart')">
            <input type="button" class="button_gen" value="Stop"    onclick="AWG.forms.submitControl('awgstop')">
            <input type="button" class="button_gen" value="Restart" onclick="AWG.forms.submitControl('awgrestart')">
          </div>

          </form>

          <!-- ============ Import modal ============ -->
          <div id="awg-import-modal" class="awg-import-modal" style="display:none">
            <div class="awg-import-inner">
              <h3>Import .conf</h3>
              <p>Paste a WireGuard/AmneziaWG <code>.conf</code>. Client-side parser shows a preview before applying.</p>
              <textarea id="awg-import-text" rows="12" cols="80"
                        placeholder="[Interface]&#10;PrivateKey = ..."></textarea>
              <div>
                <button type="button" class="form_button" onclick="AWG.import.parsePreview()">Parse &amp; Preview</button>
                <button type="button" class="form_button" onclick="AWG.import.populateFromPreview()">Populate Form</button>
                <button type="button" class="form_button" onclick="AWG.import.closeModal()">Cancel</button>
              </div>
              <div id="awg-import-preview" class="awg-import-preview"></div>
            </div>
          </div>

          </td></tr>
        </table>
      </td>
    </tr>
  </table>
</td><td width="10" align="center" valign="top">&nbsp;</td></tr>
</table>
<div id="footer"></div>

<script type="text/javascript" src="/user/amneziawg.js"></script>
</body>
</html>
