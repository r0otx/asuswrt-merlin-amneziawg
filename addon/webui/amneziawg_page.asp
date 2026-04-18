<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <meta name="version" content="0.0.0-dev">
<meta http-equiv="X-UA-Compatible" content="IE=Edge"/>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<meta HTTP-EQUIV="Pragma" CONTENT="no-cache">
<meta HTTP-EQUIV="Expires" CONTENT="-1">
<link rel="shortcut icon" href="images/favicon.png">
<link rel="icon" href="images/favicon.png">
<title>AmneziaWG</title>
<link rel="stylesheet" type="text/css" href="index_style.css">
<link rel="stylesheet" type="text/css" href="form_style.css">
<script type="text/javascript" src="/js/jquery.js"></script>
<script language="JavaScript" type="text/javascript" src="/help.js"></script>
<script language="JavaScript" type="text/javascript" src="/state.js"></script>
<script language="JavaScript" type="text/javascript" src="/general.js"></script>
<script language="JavaScript" type="text/javascript" src="/popup.js"></script>
<script language="JavaScript" type="text/javascript" src="/validator.js"></script>
<script type="text/javascript" src="/js/httpApi.js"></script>
<style>
.awg-status {
    padding: 8px 16px;
    border-radius: 4px;
    font-weight: bold;
    display: inline-block;
    font-size: 13px;
    letter-spacing: 0.5px;
    text-transform: uppercase;
}
.awg-status.running {
    background: #1a6e2e;
    color: #fff;
    border: 1px solid #2a8b42;
}
.awg-status.stopped {
    background: #8b0000;
    color: #fff;
    border: 1px solid #a00;
}
.awg-status.connecting {
    background: #b8860b;
    color: #fff;
    border: 1px solid #daa520;
}

.awg-section {
    margin: 14px 0 6px 0;
    font-size: 14px;
    font-weight: bold;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.awg-log {
    font-family: "Courier New", "Lucida Console", monospace;
    font-size: 11px;
    padding: 10px;
    height: 180px;
    overflow-y: auto;
    border: 1px solid #444;
    border-radius: 3px;
    white-space: pre-wrap;
    word-wrap: break-word;
}

.awg-btn { margin: 0 4px; }

#awg_peers_table { width: 100%; }
#awg_peers_table thead td {
    font-weight: bold;
    text-transform: uppercase;
    font-size: 11px;
    letter-spacing: 0.5px;
}
#awg_peers_table tbody td {
    padding: 6px 8px;
    font-size: 12px;
}

#awg_client_table { width: 100%; margin-top: 6px; }
#awg_client_table td { padding: 5px 8px; }
.awg-remove-btn {
    background: transparent; border: 1px solid #a00; color: #c00;
    padding: 3px 10px; border-radius: 3px; cursor: pointer; font-size: 14px;
}
.awg-remove-btn:hover { background: #a00; color: #fff; }
.awg-add-btn, .awg-import-btn {
    cursor: pointer;
    font-size: 12px;
}
.awg-ac-wrap { position:relative; display:inline-block; width:95%; }
.awg-ac-list { position:absolute; top:100%; left:0; right:0; max-height:200px; overflow-y:auto; border:1px solid #444; border-top:none; z-index:999; display:none; border-radius:0 0 4px 4px; background:#2f3a3e; }
.awg-ac-list div { padding:4px 8px; cursor:pointer; font-size:12px; }
.awg-ac-list div:hover, .awg-ac-list div.selected { background:#666; color:#fff; }
.awg-ac-list::-webkit-scrollbar { width:5px; }
.awg-ac-list::-webkit-scrollbar-thumb { background:#888; border-radius:3px; }
</style>
<script>
var custom_settings = <% get_custom_settings(); %>;
var statusTimer = null;
var v2flyList = [];
var v2flyIpList = ['telegram','google','facebook','twitter','netflix','cloudflare','fastly','cloudfront'];
function escHtml(s){
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
function loadV2flyCategories(){
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/user/v2fly_categories.htm?_=' + Date.now(), true);
    xhr.onload = function(){
        if(xhr.status === 200 && xhr.responseText.length > 0){
            v2flyList = xhr.responseText.trim().split('\n').filter(function(s){ return s; });
        }
    };
    xhr.send();
}

function initial(){
    show_menu();
    loadSettings();
    refreshStatus();
    statusTimer = setInterval(refreshStatus, 5000);
    loadV2flyCategories();
    initAutocomplete();
    initAutocompleteIp();
    checkForUpdate();
}

function checkForUpdate(){
    // Check GitHub directly from browser (no backend needed)
    var xhr = new XMLHttpRequest();
    xhr.open('GET', 'https://api.github.com/repos/r0otx/asuswrt-merlin-amneziawg/releases/latest', true);
    xhr.timeout = 10000;
    xhr.onload = function(){
        if(xhr.status !== 200) return;
        try {
            var data = JSON.parse(xhr.responseText);
            var latest = (data.tag_name || '').replace(/^v/, '');
            showVersionInfo('', latest, false);
        } catch(e){}
    };
    xhr.send();
}

function showVersionInfo(currentIgnored, latest, hasUpdateIgnored){
    // Get current version from status file
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/user/awg_status.htm?_=' + Date.now(), true);
    xhr.timeout = 3000;
    xhr.onload = function(){
        try {
            var s = JSON.parse(xhr.responseText);
            var current = s.version || '';
            var vi = document.getElementById('awg_version_info');
            var ub = document.getElementById('awg_update_btn');
            if(!vi) return;
            if(current) vi.textContent = 'v' + current;
            if(latest && current && latest !== current){
                ub.style.display = 'inline';
                ub.innerHTML = '<input type="button" class="button_gen" value="Update to v' + escHtml(latest) + '" onclick="doUpdate();" style="font-size:11px; padding:2px 10px;">';
            }
        } catch(e){}
    };
    xhr.send();
}

function doUpdate(){
    if(!confirm('Update AmneziaWG?\nVPN will be stopped. After update click Start.')) return;
    var badge = document.getElementById('awg_badge');
    badge.className = 'awg-status connecting';
    badge.innerHTML = '&#9679; Updating...';
    if(statusTimer){ clearInterval(statusTimer); statusTimer = null; }

    document.form.action_script.value = "start_awgdoupdate";
    document.form.submit();

    // Wait for update to finish (VPN stopped, new version installed), then reload
    var attempts = 0;
    setTimeout(function(){
        var poll = setInterval(function(){
            attempts++;
            var xhr = new XMLHttpRequest();
            xhr.open('GET', '/user/awg_status.htm?_=' + Date.now(), true);
            xhr.timeout = 3000;
            xhr.onload = function(){
                try {
                    var s = JSON.parse(xhr.responseText);
                    // Update done when VPN is stopped (do_update stops it)
                    if(!s.running || attempts >= 120){
                        clearInterval(poll);
                        location.reload();
                    }
                } catch(e){
                    if(attempts >= 120){ clearInterval(poll); location.reload(); }
                }
            };
            xhr.onerror = function(){ if(attempts >= 120){ clearInterval(poll); location.reload(); } };
            xhr.send();
        }, 2000);
    }, 5000);
}

function loadSettings(){
    var fields = [
        'awg_privatekey', 'awg_address', 'awg_listenport', 'awg_dns',
        'awg_peer_pubkey', 'awg_peer_psk', 'awg_peer_endpoint',
        'awg_peer_allowedips', 'awg_peer_keepalive',
        'awg_jc', 'awg_jmin', 'awg_jmax',
        'awg_s1', 'awg_s2', 'awg_s3', 'awg_s4',
        'awg_h1', 'awg_h2', 'awg_h3', 'awg_h4'
    ];
    for(var i = 0; i < fields.length; i++){
        var el = document.getElementById(fields[i]);
        if(el && custom_settings[fields[i]] != undefined){
            el.value = custom_settings[fields[i]];
        }
    }
    // Load I1-I5 from base64
    if(custom_settings.awg_initdata){
        try {
            var initLines = atob(custom_settings.awg_initdata).split('\n');
            for(var il = 0; il < initLines.length; il++){
                var ip = initLines[il].split('=');
                if(ip.length >= 2){
                    var ik = ip[0].trim().toLowerCase();
                    var ival = ip.slice(1).join('=').trim();
                    if(ik === 'i1') setVal('awg_i1', ival);
                    else if(ik === 'i2') setVal('awg_i2', ival);
                    else if(ik === 'i3') setVal('awg_i3', ival);
                    else if(ik === 'i4') setVal('awg_i4', ival);
                    else if(ik === 'i5') setVal('awg_i5', ival);
                }
            }
        } catch(e){}
    }
    // Load default policy
    var defPolicy = document.getElementById('default_policy');
    defPolicy.value = custom_settings.awg_default_policy || 'direct';
    // Load clients list
    loadClients();
    // Load geo settings
    loadGeoSettings();
    updateGeoVisibility();
}

function saveSettings(){
    var fields = [
        'awg_privatekey', 'awg_address', 'awg_listenport', 'awg_dns',
        'awg_peer_pubkey', 'awg_peer_psk', 'awg_peer_endpoint',
        'awg_peer_allowedips', 'awg_peer_keepalive',
        'awg_jc', 'awg_jmin', 'awg_jmax',
        'awg_s1', 'awg_s2', 'awg_s3', 'awg_s4',
        'awg_h1', 'awg_h2', 'awg_h3', 'awg_h4'
    ];
    for(var i = 0; i < fields.length; i++){
        var el = document.getElementById(fields[i]);
        if(el){
            var v = el.value;
            // Remove spaces from comma-separated values (Merlin truncates at spaces)
            if(fields[i] === 'awg_peer_allowedips' || fields[i] === 'awg_address' || fields[i] === 'awg_dns'){
                v = v.replace(/\s+/g, '');
            }
            custom_settings[fields[i]] = v;
        }
    }
    // Save default policy and clients
    custom_settings.awg_default_policy = document.getElementById('default_policy').value;
    custom_settings.awg_clients = serializeClients();

    // Save I1-I5 as base64 (contain HTML-unsafe chars)
    var initData = '';
    for(var ix = 1; ix <= 5; ix++){
        var iv = document.getElementById('awg_i' + ix);
        if(iv && iv.value) initData += 'I' + ix + ' = ' + iv.value + '\n';
    }
    custom_settings.awg_initdata = initData ? btoa(initData) : '';

    // Save geo settings
    custom_settings.awg_geo_v2fly = document.getElementById('awg_geo_v2fly').value;
    custom_settings.awg_geo_v2fly_ip = document.getElementById('awg_geo_v2fly_ip').value;
    custom_settings.awg_geo_custom_domains = document.getElementById('geo_custom_domains').value;
    custom_settings.awg_geo_custom_ips = document.getElementById('geo_custom_ips').value;
    custom_settings.awg_geo_autoupdate = document.getElementById('geo_autoupdate').checked ? '1' : '0';

    // Basic validation
    var pk = document.getElementById('awg_privatekey').value;
    var pubk = document.getElementById('awg_peer_pubkey').value;
    var ep = document.getElementById('awg_peer_endpoint').value;
    if(!pk || !pubk || !ep){
        alert('Required: Private Key, Peer Public Key, and Endpoint.');
        return;
    }
    if(pk.length !== 44 || pubk.length !== 44){
        alert('Invalid key format. Keys must be 44 characters (base64).');
        return;
    }
    if(ep.indexOf(':') === -1){
        alert('Endpoint must include port (e.g. server:51820).');
        return;
    }

    document.getElementById('amng_custom').value = JSON.stringify(custom_settings);
    document.form.action_script.value = "start_awgsaveconf";
    document.form.submit();
    setTimeout(function(){ location.reload(); }, 15000);
}

// === Routing: per-device with individual policies ===

function loadClients(){
    var data = custom_settings.awg_clients || '';
    var tbody = document.getElementById('awg_client_rows');
    tbody.innerHTML = '';
    if(!data) return;
    var entries = data.split(';');
    for(var i = 0; i < entries.length; i++){
        if(!entries[i]) continue;
        var parts = entries[i].split(',');
        addClientRow(parts[0] || '', parts[1] || '', parts[2] || 'vpn_all');
    }
    updateGeoVisibility();
}

function addClientRow(ip, name, policy){
    var tbody = document.getElementById('awg_client_rows');
    var tr = document.createElement('tr');
    policy = policy || 'vpn_all';
    tr.innerHTML =
        '<td><input type="text" class="client_ip input_25_table" value="' + escHtml(ip) + '" placeholder="192.168.1.100"></td>' +
        '<td><input type="text" class="client_name input_25_table" value="' + escHtml(name) + '" placeholder="iPhone, PS5, TV..."></td>' +
        '<td><select class="client_policy input_option" onchange="updateGeoVisibility();" style="width:100%;">' +
            '<option value="vpn_all"' + (policy==='vpn_all'?' selected':'') + '>VPN (All)</option>' +
            '<option value="vpn_geo"' + (policy==='vpn_geo'?' selected':'') + '>VPN (Geo)</option>' +
            '<option value="direct"' + (policy==='direct'?' selected':'') + '>Direct</option>' +
        '</select></td>' +
        '<td style="text-align:center;"><button type="button" class="awg-remove-btn" onclick="this.closest(\'tr\').remove(); updateGeoVisibility();">&times;</button></td>';
    tbody.appendChild(tr);
    updateGeoVisibility();
}

function serializeClients(){
    var rows = document.querySelectorAll('#awg_client_rows tr');
    var parts = [];
    for(var i = 0; i < rows.length; i++){
        var ip = rows[i].querySelector('.client_ip').value.trim();
        var name = rows[i].querySelector('.client_name').value.trim();
        var policy = rows[i].querySelector('.client_policy').value;
        if(ip) parts.push(ip + ',' + name.replace(/[,;]/g, ' ') + ',' + policy);
    }
    return parts.join(';');
}

function updateGeoVisibility(){
    // Show geo settings if ANY device uses vpn_geo or default policy is vpn_geo
    var defPolicy = document.getElementById('default_policy').value;
    var hasGeo = (defPolicy === 'vpn_geo');
    if(!hasGeo){
        var selects = document.querySelectorAll('.client_policy');
        for(var i = 0; i < selects.length; i++){
            if(selects[i].value === 'vpn_geo'){ hasGeo = true; break; }
        }
    }
    document.getElementById('geo_section').style.display = hasGeo ? '' : 'none';
}

// === GeoIP / GeoSite ===

function loadGeoSettings(){
    var v2fly = document.getElementById('awg_geo_v2fly');
    if(v2fly) v2fly.value = custom_settings.awg_geo_v2fly || '';
    var v2flyIp = document.getElementById('awg_geo_v2fly_ip');
    if(v2flyIp) v2flyIp.value = custom_settings.awg_geo_v2fly_ip || '';
    // Custom
    var cd = document.getElementById('geo_custom_domains');
    if(cd) cd.value = custom_settings.awg_geo_custom_domains || '';
    var ci = document.getElementById('geo_custom_ips');
    if(ci) ci.value = custom_settings.awg_geo_custom_ips || '';
    // Auto-update
    var au = document.getElementById('geo_autoupdate');
    if(au) au.checked = (custom_settings.awg_geo_autoupdate === '1');
}

function getCheckedValues(prefix){
    var checks = document.querySelectorAll('input[data-group="' + prefix + '"]:checked');
    var vals = [];
    for(var i = 0; i < checks.length; i++) vals.push(checks[i].value);
    return vals.join(',');
}

function setCheckedValues(prefix, csv){
    var vals = csv.split(',');
    var checks = document.querySelectorAll('input[data-group="' + prefix + '"]');
    for(var i = 0; i < checks.length; i++){
        checks[i].checked = (vals.indexOf(checks[i].value) !== -1);
    }
}

function updateGeoLists(){
    var btn = document.getElementById('btn_geo_update');
    var isDownload = btn && btn.value === 'Download Lists';
    var msg = isDownload
        ? 'Download all GeoIP and domain lists?\nThis may take 1-2 minutes.'
        : 'Force re-download all GeoIP and domain lists?\nThis may take 1-2 minutes.';
    if(!confirm(msg)) return;
    var log = document.getElementById('awg_log');
    if(log) log.textContent = 'Downloading geo lists... Please wait.';
    document.form.action_script.value = "start_awgupdategeo";
    document.form.submit();
    setTimeout(function(){ location.reload(); }, 60000);
}

function fetchDhcpClients(){
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/appGet.cgi?hook=get_clientlist()&_=' + Date.now(), true);
    xhr.onload = function(){
        if(xhr.status === 200){
            try {
                var data = JSON.parse(xhr.responseText);
                var cl = data.get_clientlist || data;
                var lines = [];
                for(var key in cl){
                    if(!cl.hasOwnProperty(key)) continue;
                    var c = cl[key];
                    if(c && typeof c === 'object' && c.ip){
                        lines.push({ip: c.ip, name: c.name || c.nickName || key});
                    }
                }
                if(lines.length > 0){
                    showClientPicker(lines);
                } else {
                    fetchDhcpLeases();
                }
            } catch(e){
                fetchDhcpLeases();
            }
        } else {
            fetchDhcpLeases();
        }
    };
    xhr.onerror = function(){ fetchDhcpLeases(); };
    xhr.send();
}

function fetchDhcpLeases(){
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/update_clients.asp?_=' + Date.now(), true);
    xhr.onload = function(){
        if(xhr.status === 200){
            var lines = [];
            var text = xhr.responseText;
            // dnsmasq.leases format: expiry mac ip hostname clientid
            var rows = text.match(/\d+\.\d+\.\d+\.\d+/g);
            if(rows){
                // Re-parse line by line for ip + hostname
                var rawLines = text.split('\n');
                for(var i = 0; i < rawLines.length; i++){
                    var parts = rawLines[i].trim().split(/\s+/);
                    if(parts.length >= 4 && parts[2].match(/^\d+\.\d+\.\d+\.\d+$/)){
                        lines.push({ip: parts[2], name: parts[3] === '*' ? parts[1] : parts[3]});
                    }
                }
            }
            if(lines.length > 0){
                showClientPicker(lines);
            } else {
                var input = prompt('Enter device IPs to add (comma-separated):');
                if(input) addManualIPs(input);
            }
        }
    };
    xhr.onerror = function(){
        var input = prompt('Enter device IPs to add (comma-separated):');
        if(input) addManualIPs(input);
    };
    xhr.send();
}

function showClientPicker(clients){
    var msg = 'DHCP clients:\n\n';
    for(var i = 0; i < clients.length; i++){
        msg += (i+1) + ') ' + clients[i].ip + ' — ' + clients[i].name + '\n';
    }
    msg += '\nEnter numbers (e.g. 1,3,5) or IPs directly:';
    var input = prompt(msg);
    if(!input) return;

    var items = input.split(',');
    for(var i = 0; i < items.length; i++){
        var v = items[i].trim();
        var num = parseInt(v);
        if(!isNaN(num) && num >= 1 && num <= clients.length){
            var c = clients[num - 1];
            addClientRow(c.ip, c.name, 'vpn_all');
        } else if(v.match(/^\d+\.\d+\.\d+\.\d+$/)){
            addClientRow(v, '', 'vpn_all');
        }
    }
}

function addManualIPs(input){
    var ips = input.split(',');
    for(var i = 0; i < ips.length; i++){
        var ip = ips[i].trim();
        if(ip) addClientRow(ip, '', 'vpn_all');
    }
}

function awgAction(action){
    document.form.action_script.value = action;
    document.form.submit();
    var badge = document.getElementById('awg_badge');
    var isStop = action.indexOf('stop') !== -1;
    var expect = !isStop;

    // Stop periodic refresh while action runs
    if(statusTimer){ clearInterval(statusTimer); statusTimer = null; }
    document.getElementById('btn_start').disabled = true;
    document.getElementById('btn_stop').disabled = true;
    document.getElementById('btn_restart').disabled = true;

    // Show transitional status
    badge.className = 'awg-status connecting';
    badge.innerHTML = isStop ? '&#9679; Stopping...' : '&#9679; Connecting...';

    // Poll until status is fully ready
    var attempts = 0;
    var poll = setInterval(function(){
        attempts++;
        var xhr = new XMLHttpRequest();
        xhr.open('GET', '/user/awg_status.htm?_=' + Date.now(), true);
        xhr.timeout = 3000;
        xhr.onload = function(){
            try {
                var s = JSON.parse(xhr.responseText);
                // For start: wait until running AND has public key (fully ready)
                // For stop: wait until not running
                var ready = (s.running === expect);
                if(ready || attempts >= 90){
                    clearInterval(poll);
                    updateStatusUI(s);
                    statusTimer = setInterval(refreshStatus, 5000);
                    document.getElementById('btn_start').disabled = false;
                    document.getElementById('btn_stop').disabled = false;
                    document.getElementById('btn_restart').disabled = false;
                }
            } catch(e){
                if(attempts >= 90){ clearInterval(poll); refreshStatus(); document.getElementById('btn_start').disabled = false; document.getElementById('btn_stop').disabled = false; document.getElementById('btn_restart').disabled = false; }
            }
        };
        xhr.onerror = function(){ if(attempts >= 90){ clearInterval(poll); refreshStatus(); document.getElementById('btn_start').disabled = false; document.getElementById('btn_stop').disabled = false; document.getElementById('btn_restart').disabled = false; } };
        xhr.send();
    }, 2000);
}

function showLoading(){}
function hideLoading(){}

function refreshStatus(){
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/user/awg_status.htm?_=' + Date.now(), true);
    xhr.timeout = 3000;
    xhr.onload = function(){
        if(xhr.status === 200){
            try {
                var status = JSON.parse(xhr.responseText);
                updateStatusUI(status);
            } catch(e) {
                setOfflineUI();
            }
        } else {
            setOfflineUI();
        }
    };
    xhr.onerror = function(){ setOfflineUI(); };
    xhr.ontimeout = function(){ setOfflineUI(); };
    xhr.send();
}

function updateStatusUI(s){
    var badge = document.getElementById('awg_badge');
    var info = document.getElementById('awg_info');
    var peers = document.getElementById('awg_peers');
    var logbox = document.getElementById('awg_log');

    if(s.running){
        badge.className = 'awg-status running';
        badge.innerHTML = '&#9679; Connected';
        document.getElementById('btn_start').style.display = 'none';
        document.getElementById('btn_stop').style.display = '';
        document.getElementById('btn_restart').style.display = '';
    } else {
        badge.className = 'awg-status stopped';
        badge.innerHTML = '&#9679; Stopped';
        document.getElementById('btn_start').style.display = '';
        document.getElementById('btn_stop').style.display = 'none';
        document.getElementById('btn_restart').style.display = 'none';
    }

    info.innerHTML = '';
    if(s.interface_addr) info.innerHTML += 'Address: ' + escHtml(s.interface_addr) + '<br>';
    if(s.public_key) info.innerHTML += 'Public Key: ' + escHtml(s.public_key.substring(0,12)) + '...<br>';
    if(s.listen_port) info.innerHTML += 'Listen Port: ' + escHtml(s.listen_port) + '<br>';

    var html = '';
    if(s.peers && s.peers.length > 0){
        for(var i = 0; i < s.peers.length; i++){
            var p = s.peers[i];
            html += '<tr>';
            html += '<td>' + escHtml(p.endpoint || '-') + '</td>';
            html += '<td>' + escHtml(p.allowed_ips || '-') + '</td>';
            html += '<td>' + escHtml(p.transfer_rx || '0 B') + ' / ' + escHtml(p.transfer_tx || '0 B') + '</td>';
            html += '<td>' + escHtml(p.latest_handshake || 'never') + '</td>';
            html += '</tr>';
        }
    }
    peers.innerHTML = html;

    if(s.log) logbox.textContent = s.log;

    // Route info
    var rulesEl = document.getElementById('awg_active_rules');
    if(s.running){
        var infoParts = [];
        if(s.active_rules > 0) infoParts.push(s.active_rules + ' routing rule(s)');
        if(s.ipset_count > 0) infoParts.push(s.ipset_count + ' IP ranges');
        if(s.geo_domains > 0) infoParts.push(s.geo_domains + ' domain rules');
        rulesEl.innerHTML = infoParts.join(' &middot; ') || 'no rules active';
        rulesEl.style.color = '#93E7FF';
    } else {
        rulesEl.innerHTML = '';
    }

    // Update geo button text based on database availability
    var geoBtn = document.getElementById('btn_geo_update');
    if(geoBtn){
        if(s.geo_downloaded){
            geoBtn.value = 'Update Now';
        } else {
            geoBtn.value = 'Download Lists';
            geoBtn.style.fontWeight = 'bold';
        }
    }
}

function setOfflineUI(){
    var badge = document.getElementById('awg_badge');
    badge.className = 'awg-status stopped';
    badge.innerHTML = '&#9679; Stopped';
    document.getElementById('btn_start').style.display = '';
    document.getElementById('btn_stop').style.display = 'none';
    document.getElementById('btn_restart').style.display = 'none';
}

var _initParams = {};

function importConfig(){
    var fileInput = document.getElementById('awg_config_file');
    if(!fileInput){
        fileInput = document.createElement('input');
        fileInput.type = 'file';
        fileInput.id = 'awg_config_file';
        fileInput.accept = '.conf,.txt';
        fileInput.style.display = 'none';
        document.body.appendChild(fileInput);
    }
    fileInput.value = '';
    fileInput.onchange = function(){
        if(!fileInput.files || !fileInput.files[0]) return;
        var reader = new FileReader();
        reader.onload = function(e){ parseConfig(e.target.result); };
        reader.readAsText(fileInput.files[0]);
    };
    fileInput.click();
}

function parseConfig(text){
    if(!text) return;

    var lines = text.split('\n');
    var section = '';
    for(var i = 0; i < lines.length; i++){
        var line = lines[i].trim();
        if(line === '[Interface]'){ section = 'iface'; continue; }
        if(line === '[Peer]'){ section = 'peer'; continue; }
        if(!line || line.charAt(0) === '#') continue;

        var parts = line.split('=');
        if(parts.length < 2) continue;
        var key = parts[0].trim();
        var val = parts.slice(1).join('=').trim();

        if(section === 'iface'){
            switch(key){
                case 'PrivateKey': setVal('awg_privatekey', val); break;
                case 'Address':    setVal('awg_address', val); break;
                case 'ListenPort': setVal('awg_listenport', val); break;
                case 'DNS':        setVal('awg_dns', val); break;
                case 'Jc':         setVal('awg_jc', val); break;
                case 'Jmin':       setVal('awg_jmin', val); break;
                case 'Jmax':       setVal('awg_jmax', val); break;
                case 'S1':         setVal('awg_s1', val); break;
                case 'S2':         setVal('awg_s2', val); break;
                case 'S3':         setVal('awg_s3', val); break;
                case 'S4':         setVal('awg_s4', val); break;
                case 'H1':         setVal('awg_h1', val); break;
                case 'H2':         setVal('awg_h2', val); break;
                case 'H3':         setVal('awg_h3', val); break;
                case 'H4':         setVal('awg_h4', val); break;
                case 'I1': setVal('awg_i1', val); break;
                case 'I2': setVal('awg_i2', val); break;
                case 'I3': setVal('awg_i3', val); break;
                case 'I4': setVal('awg_i4', val); break;
                case 'I5': setVal('awg_i5', val); break;
            }
        } else if(section === 'peer'){
            switch(key){
                case 'PublicKey':          setVal('awg_peer_pubkey', val); break;
                case 'PresharedKey':       setVal('awg_peer_psk', val); break;
                case 'Endpoint':           setVal('awg_peer_endpoint', val); break;
                case 'AllowedIPs':         setVal('awg_peer_allowedips', val); break;
                case 'PersistentKeepalive': setVal('awg_peer_keepalive', val); break;
            }
        }
    }
    alert('Config imported. Review the fields and click Apply.');
}

function setVal(id, val){
    var el = document.getElementById(id);
    if(el) el.value = val;
}

function initAutocomplete(){
    var input = document.getElementById('awg_geo_v2fly');
    if(!input) return;
    var wrap = document.createElement('div');
    wrap.className = 'awg-ac-wrap';
    input.parentNode.insertBefore(wrap, input);
    wrap.appendChild(input);
    var list = document.createElement('div');
    list.className = 'awg-ac-list';
    list.id = 'awg_ac_list';
    wrap.appendChild(list);
    var selIdx = -1;

    function getLastToken(){
        var val = input.value;
        var parts = val.split(',');
        return parts[parts.length - 1].trim();
    }

    function getExisting(){
        return input.value.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s; });
    }

    function showSuggestions(){
        var q = getLastToken().toLowerCase();
        var existing = getExisting();
        list.innerHTML = '';
        selIdx = -1;
        if(q.length < 1){ list.style.display = 'none'; return; }
        var matches = v2flyList.filter(function(s){
            return s.indexOf(q) !== -1 && existing.indexOf(s) === -1;
        }).slice(0, 15);
        if(matches.length === 0){ list.style.display = 'none'; return; }
        for(var i = 0; i < matches.length; i++){
            var d = document.createElement('div');
            d.textContent = matches[i];
            d.onmousedown = function(e){ e.preventDefault(); pickItem(this.textContent); };
            list.appendChild(d);
        }
        list.style.display = 'block';
    }

    function pickItem(val){
        var parts = input.value.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s; });
        parts.pop();
        parts.push(val);
        input.value = parts.join(',') + ',';
        list.style.display = 'none';
        input.focus();
    }

    input.addEventListener('input', showSuggestions);
    input.addEventListener('focus', showSuggestions);
    input.addEventListener('blur', function(){ setTimeout(function(){ list.style.display = 'none'; }, 200); });
    input.addEventListener('keydown', function(e){
        var items = list.querySelectorAll('div');
        if(e.key === 'ArrowDown'){ e.preventDefault(); selIdx = Math.min(selIdx + 1, items.length - 1); }
        else if(e.key === 'ArrowUp'){ e.preventDefault(); selIdx = Math.max(selIdx - 1, 0); }
        else if(e.key === 'Enter' && selIdx >= 0){ e.preventDefault(); pickItem(items[selIdx].textContent); return; }
        else return;
        for(var i = 0; i < items.length; i++) items[i].className = (i === selIdx) ? 'selected' : '';
    });
}

function initAutocompleteIp(){
    var input = document.getElementById('awg_geo_v2fly_ip');
    if(!input) return;
    var wrap = document.createElement('div');
    wrap.className = 'awg-ac-wrap';
    input.parentNode.insertBefore(wrap, input);
    wrap.appendChild(input);
    var list = document.createElement('div');
    list.className = 'awg-ac-list';
    list.id = 'awg_ac_list_ip';
    wrap.appendChild(list);
    var selIdx = -1;

    function getLastToken(){
        var parts = input.value.split(',');
        return parts[parts.length - 1].trim();
    }
    function getExisting(){
        return input.value.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s; });
    }
    function showSuggestions(){
        var q = getLastToken().toLowerCase();
        var existing = getExisting();
        list.innerHTML = '';
        selIdx = -1;
        if(q.length < 1){ list.style.display = 'none'; return; }
        var matches = v2flyIpList.filter(function(s){
            return s.indexOf(q) !== -1 && existing.indexOf(s) === -1;
        }).slice(0, 15);
        if(matches.length === 0){ list.style.display = 'none'; return; }
        for(var i = 0; i < matches.length; i++){
            var d = document.createElement('div');
            d.textContent = matches[i];
            d.onmousedown = function(e){ e.preventDefault(); pickItem(this.textContent); };
            list.appendChild(d);
        }
        list.style.display = 'block';
    }
    function pickItem(val){
        var parts = input.value.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s; });
        parts.pop();
        parts.push(val);
        input.value = parts.join(',') + ',';
        list.style.display = 'none';
        input.focus();
    }
    input.addEventListener('input', showSuggestions);
    input.addEventListener('focus', showSuggestions);
    input.addEventListener('blur', function(){ setTimeout(function(){ list.style.display = 'none'; }, 200); });
    input.addEventListener('keydown', function(e){
        var items = list.querySelectorAll('div');
        if(e.key === 'ArrowDown'){ e.preventDefault(); selIdx = Math.min(selIdx + 1, items.length - 1); }
        else if(e.key === 'ArrowUp'){ e.preventDefault(); selIdx = Math.max(selIdx - 1, 0); }
        else if(e.key === 'Enter' && selIdx >= 0){ e.preventDefault(); pickItem(items[selIdx].textContent); return; }
        else return;
        for(var i = 0; i < items.length; i++) items[i].className = (i === selIdx) ? 'selected' : '';
    });
}
</script>
</head>
<body onload="initial();" onunload="clearInterval(statusTimer);">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="about:blank" width="0" height="0" frameborder="0"></iframe>

<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="productid" value="<% nvram_get("productid"); %>">
<input type="hidden" name="current_page" value="">
<input type="hidden" name="next_page" value="">
<input type="hidden" name="modified" value="0">
<input type="hidden" name="action_mode" value="apply">
<input type="hidden" name="action_script" value="">
<input type="hidden" name="action_wait" value="15">
<input type="hidden" name="amng_custom" id="amng_custom" value="">

<table class="content" align="center" cellpadding="0" cellspacing="0">
<tr>
    <td width="17">&nbsp;</td>
    <td valign="top" width="202">
        <div id="mainMenu"></div>
        <div id="subMenu"></div>
    </td>
    <td valign="top">
        <div id="tabMenu" class="submenuBlock"></div>
        <table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
        <tr>
            <td valign="top">

            <!-- ==================== STATUS ==================== -->
            <table width="760px" border="0" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTitle" id="FormTitle">
            <tr><td bgcolor="#4D595D" valign="top">
                <div>&nbsp;</div>
                <div class="formfonttitle" style="display:flex; align-items:center; gap:10px;">
                    <span style="font-size:20px; font-weight:bold; letter-spacing:1px;">AmneziaWG</span>
                    <span style="font-size:13px; font-weight:normal;">VPN Client</span>
                    <span id="awg_version_info" style="margin-left:auto; font-size:11px; opacity:0.6;"></span>
                    <span id="awg_update_btn" style="display:none;"></span>
                </div>
                <div style="margin:10px 0 10px 5px;" class="splitLine"></div>

                <!-- Status & Actions -->
                <table width="100%" border="0" cellpadding="4" cellspacing="0">
                <tr>
                    <th width="20%">Status</th>
                    <td>
                        <span id="awg_badge" class="awg-status stopped">Stopped</span>
                        &nbsp;&nbsp;
                        <input type="button" id="btn_start" class="button_gen awg-btn" value="Start" onclick="awgAction('start_awgstart');">
                        <input type="button" id="btn_stop" class="button_gen awg-btn" value="Stop" style="display:none;" onclick="awgAction('start_awgstop');">
                        <input type="button" id="btn_restart" class="button_gen awg-btn" value="Restart" style="display:none;" onclick="awgAction('start_awgrestart');">
                    </td>
                </tr>
                <tr>
                    <th width="20%">Interface</th>
                    <td><span id="awg_info">-</span></td>
                </tr>
                </table>

                <!-- Peers Table -->
                <div class="awg-section">Connected Peers</div>
                <table width="100%" border="0" cellpadding="4" cellspacing="0" class="FormTable_table" id="awg_peers_table">
                <thead><tr>
                    <td width="25%">Endpoint</td>
                    <td width="25%">Allowed IPs</td>
                    <td width="25%">Transfer (RX/TX)</td>
                    <td width="25%">Last Handshake</td>
                </tr></thead>
                <tbody id="awg_peers">
                    <tr><td colspan="4" style="text-align:center; color:#666;">No peers</td></tr>
                </tbody>
                </table>

                <div style="margin:15px 0 10px 0;" class="splitLine"></div>

                <!-- ==================== CONFIG ==================== -->
                <div class="awg-section">Configuration</div>
                <div style="margin-bottom:8px;">
                    <input type="button" class="button_gen" value="Import Config" onclick="importConfig();">
                    <span style="color:#AAA; margin-left:10px; font-size:12px;">Upload .conf file from Amnezia VPN client</span>
                </div>

                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable">
                <thead><tr><td colspan="2">Interface</td></tr></thead>
                <tr>
                    <th width="35%">Private Key</th>
                    <td><input type="password" class="input_32_table" id="awg_privatekey" maxlength="64" autocomplete="off"></td>
                </tr>
                <tr>
                    <th>Address</th>
                    <td><input type="text" class="input_20_table" id="awg_address" maxlength="32" placeholder="10.7.0.2/24"></td>
                </tr>
                <tr>
                    <th>Listen Port</th>
                    <td><input type="text" class="input_6_table" id="awg_listenport" maxlength="5" placeholder="51820"></td>
                </tr>
                <tr>
                    <th>DNS</th>
                    <td><input type="text" class="input_20_table" id="awg_dns" maxlength="64" placeholder="1.1.1.1"></td>
                </tr>
                </table>

                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable" style="margin-top:8px;">
                <thead><tr><td colspan="2">Peer</td></tr></thead>
                <tr>
                    <th width="35%">Public Key</th>
                    <td><input type="text" class="input_32_table" id="awg_peer_pubkey" maxlength="64"></td>
                </tr>
                <tr>
                    <th>Preshared Key</th>
                    <td><input type="password" class="input_32_table" id="awg_peer_psk" maxlength="64" autocomplete="off" placeholder="(optional)"></td>
                </tr>
                <tr>
                    <th>Endpoint</th>
                    <td><input type="text" class="input_25_table" id="awg_peer_endpoint" maxlength="64" placeholder="server.example.com:51820"></td>
                </tr>
                <tr>
                    <th>Allowed IPs</th>
                    <td><input type="text" class="input_25_table" id="awg_peer_allowedips" maxlength="128" placeholder="0.0.0.0/0"></td>
                </tr>
                <tr>
                    <th>Persistent Keepalive</th>
                    <td><input type="text" class="input_6_table" id="awg_peer_keepalive" maxlength="4" placeholder="25"> sec</td>
                </tr>
                </table>

                <!-- ==================== OBFUSCATION ==================== -->
                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable" style="margin-top:8px;">
                <thead><tr><td colspan="2">AmneziaWG Obfuscation</td></tr></thead>
                <tr>
                    <th width="35%">Jc (junk packet count)</th>
                    <td><input type="text" class="input_6_table" id="awg_jc" maxlength="3" placeholder="4"> (0-128)</td>
                </tr>
                <tr>
                    <th>Jmin (min junk size)</th>
                    <td><input type="text" class="input_6_table" id="awg_jmin" maxlength="5" placeholder="40"> bytes</td>
                </tr>
                <tr>
                    <th>Jmax (max junk size)</th>
                    <td><input type="text" class="input_6_table" id="awg_jmax" maxlength="5" placeholder="70"> bytes</td>
                </tr>
                <tr>
                    <th>S1 (init padding)</th>
                    <td><input type="text" class="input_6_table" id="awg_s1" maxlength="3" placeholder="20"> bytes</td>
                </tr>
                <tr>
                    <th>S2 (response padding)</th>
                    <td><input type="text" class="input_6_table" id="awg_s2" maxlength="3" placeholder="30"> bytes</td>
                </tr>
                <tr>
                    <th>S3</th>
                    <td><input type="text" class="input_6_table" id="awg_s3" maxlength="3" placeholder="0"> bytes</td>
                </tr>
                <tr>
                    <th>S4</th>
                    <td><input type="text" class="input_6_table" id="awg_s4" maxlength="3" placeholder="0"> bytes</td>
                </tr>
                <tr>
                    <th>H1 (init header)</th>
                    <td><input type="text" class="input_25_table" id="awg_h1" maxlength="32" placeholder="1234567891"></td>
                </tr>
                <tr>
                    <th>H2 (response header)</th>
                    <td><input type="text" class="input_25_table" id="awg_h2" maxlength="32" placeholder="1987654321"></td>
                </tr>
                <tr>
                    <th>H3 (cookie header)</th>
                    <td><input type="text" class="input_25_table" id="awg_h3" maxlength="32" placeholder="1112223334"></td>
                </tr>
                <tr>
                    <th>H4 (data header)</th>
                    <td><input type="text" class="input_25_table" id="awg_h4" maxlength="32" placeholder="4445556667"></td>
                </tr>
                <tr>
                    <th>I1 (init junk)</th>
                    <td><input type="text" class="input_32_table" id="awg_i1" style="width:95%; font-size:11px;" maxlength="512" placeholder="Auto-filled by Import Config"></td>
                </tr>
                <tr>
                    <th>I2</th>
                    <td><input type="text" class="input_32_table" id="awg_i2" style="width:95%; font-size:11px;" maxlength="512" placeholder="(optional)"></td>
                </tr>
                <tr>
                    <th>I3</th>
                    <td><input type="text" class="input_32_table" id="awg_i3" style="width:95%; font-size:11px;" maxlength="512" placeholder="(optional)"></td>
                </tr>
                <tr>
                    <th>I4</th>
                    <td><input type="text" class="input_32_table" id="awg_i4" style="width:95%; font-size:11px;" maxlength="512" placeholder="(optional)"></td>
                </tr>
                <tr>
                    <th>I5</th>
                    <td><input type="text" class="input_32_table" id="awg_i5" style="width:95%; font-size:11px;" maxlength="512" placeholder="(optional)"></td>
                </tr>
                </table>

                <!-- ==================== ROUTING ==================== -->
                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable" style="margin-top:8px;">
                <thead><tr><td colspan="2">Routing Policy</td></tr></thead>
                <tr>
                    <th width="35%">Default Policy</th>
                    <td>
                        <select id="default_policy" class="input_option" onchange="updateGeoVisibility();"
                                style="font-size:13px; font-weight:bold;">
                            <option value="direct">Direct (no VPN)</option>
                            <option value="vpn_all">VPN — All Traffic</option>
                            <option value="vpn_geo">VPN — Geo Only</option>
                        </select>
                        <span style="color:#666; font-size:11px; margin-left:8px;">For devices not in the list below</span>
                        <span id="awg_active_rules" style="margin-left:12px; color:#666; font-size:11px;"></span>
                    </td>
                </tr>
                </table>

                <div class="awg-section">Device Rules</div>
                <table width="100%" border="0" cellpadding="4" cellspacing="0" class="FormTable_table" id="awg_client_table">
                <thead><tr>
                    <td width="25%">IP Address</td>
                    <td width="25%">Device Name</td>
                    <td width="30%">Policy</td>
                    <td width="20%">Action</td>
                </tr></thead>
                <tbody id="awg_client_rows">
                </tbody>
                </table>
                <div style="margin-top:6px;">
                    <input type="button" class="button_gen" value="+ Add Device" onclick="addClientRow('','','vpn_all');">
                    <input type="button" class="button_gen" value="+ From DHCP List" onclick="fetchDhcpClients();" style="margin-left:6px;">
                </div>

                <!-- ==================== GEO ROUTING ==================== -->
                <div id="geo_section" style="display:none;">

                <div style="border:1px solid #fc0; border-radius:4px; padding:10px 14px; margin-top:10px; font-size:12px; color:#fc0;">
                    <b>Важно:</b> Для работы VPN Geo устройства должны использовать роутер как DNS-сервер.<br>
                    iPhone: Настройки &gt; Wi-Fi &gt; (i) &gt; DNS &gt; Вручную &gt; только <% nvram_get("lan_ipaddr"); %><br>
                    macOS/Windows: укажите <% nvram_get("lan_ipaddr"); %> как DNS в настройках сети. Отключите DNS-over-HTTPS в браузере.
                </div>

                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable" style="margin-top:8px;">
                <thead><tr><td colspan="2">GeoIP — Route by Service IP</td></tr></thead>
                <tr>
                    <th width="35%">GeoIP Service Lists<br><span style="font-weight:normal; font-size:11px; color:#888;">github.com/Loyalsoldier/geoip</span></th>
                    <td>
                        <input type="text" class="input_32_table" id="awg_geo_v2fly_ip" style="width:95%;" maxlength="512"
                            placeholder="telegram,google,facebook,twitter,netflix,cloudflare">
                        <br><span style="color:#888; font-size:11px;">Comma-separated. IP ranges for services: telegram, google, facebook, twitter, netflix, cloudflare, apple, amazon, microsoft, github, stripe, openai ...</span>
                        <div style="color:#666; font-size:11px; margin-top:3px;">Works without DNS — direct IP matching. Ideal for Telegram, messengers, etc.</div>
                    </td>
                </tr>
                </table>

                <table width="100%" border="1" cellpadding="4" cellspacing="0" class="FormTable" style="margin-top:8px;">
                <thead><tr><td colspan="2">GeoSite — Route by Service / Domain</td></tr></thead>
                <tr>
                    <th width="35%">GeoSite Service Lists<br><span style="font-weight:normal; font-size:11px; color:#888;">github.com/v2fly/domain-list-community</span></th>
                    <td>
                        <input type="text" class="input_32_table" id="awg_geo_v2fly" style="width:95%;" maxlength="512"
                            placeholder="youtube,google,discord,netflix,telegram,twitter,instagram,facebook,tiktok,spotify">
                        <br><span style="color:#888; font-size:11px;">Comma-separated. 1400+ lists: youtube, google, discord, netflix, telegram, twitter, instagram, facebook, tiktok, spotify, steam, apple, microsoft, amazon, openai, github, whatsapp, category-media, category-games, category-dev ...</span>
                    </td>
                </tr>
                <tr>
                    <th>Custom Domains</th>
                    <td>
                        <input type="text" class="input_32_table" id="geo_custom_domains" style="width:95%;"
                               maxlength="2000" placeholder="example.com,another.org,service.net">
                        <div style="color:#666; font-size:11px; margin-top:3px;">Comma-separated. DNS-resolved → routed through VPN</div>
                    </td>
                </tr>
                <tr>
                    <th>Custom IPs / Subnets</th>
                    <td>
                        <input type="text" class="input_32_table" id="geo_custom_ips" style="width:95%;"
                               maxlength="2000" placeholder="8.8.8.8,1.1.1.0/24,203.0.113.0/24">
                        <div style="color:#666; font-size:11px; margin-top:3px;">Comma-separated IPs or CIDR subnets</div>
                    </td>
                </tr>
                <tr>
                    <th>Auto-update Lists</th>
                    <td>
                        <label><input type="checkbox" id="geo_autoupdate"> Daily at 4:00 AM</label>
                        &nbsp;&nbsp;
                        <input type="button" class="button_gen" id="btn_geo_update" value="Update Now" onclick="updateGeoLists();">
                    </td>
                </tr>
                </table>

                </div>

                <!-- Apply -->
                <div style="margin-top:12px; text-align:center;">
                    <input type="button" class="button_gen" value="Apply" onclick="saveSettings();">
                </div>

                <!-- ==================== LOG ==================== -->
                <div class="awg-section" style="margin-top:15px;">Log</div>
                <div id="awg_log" class="awg-log">Waiting for data...</div>
                <div style="text-align:right; font-size:11px; opacity:0.5; margin-top:4px;">
                    <a href="https://github.com/r0otx/asuswrt-merlin-amneziawg" target="_blank" style="text-decoration:none;">&copy; r0otx</a>
                </div>

            </td></tr>
            </table>

            </td>
        </tr>
        </table>
    </td>
</tr>
</table>
</form>

<div id="footer"></div>
</body>
</html>
