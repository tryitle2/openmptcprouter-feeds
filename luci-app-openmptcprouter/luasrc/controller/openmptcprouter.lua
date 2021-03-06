local tools = require "luci.tools.status"
local sys   = require "luci.sys"
local json  = require("luci.json")
local ucic = uci.cursor()
module("luci.controller.openmptcprouter", package.seeall)

function index()
--	entry({"admin", "openmptcprouter"}, firstchild(), _("OpenMPTCProuter"), 19).index = true
--	entry({"admin", "openmptcprouter", "wizard"}, template("openmptcprouter/wizard"), _("Wizard"), 1).leaf = true
--	entry({"admin", "openmptcprouter", "wizard_add"}, post("wizard_add")).leaf = true
	entry({"admin", "system", "openmptcprouter"}, alias("admin", "system", "openmptcprouter", "wizard"), _("OpenMPTCProuter"), 1)
	entry({"admin", "system", "openmptcprouter", "wizard"}, template("openmptcprouter/wizard"), _("Settings Wizard"), 1)
	entry({"admin", "system", "openmptcprouter", "wizard_add"}, post("wizard_add"))
	entry({"admin", "system", "openmptcprouter", "status"}, template("openmptcprouter/wanstatus"), _("Status"), 2).leaf = true
	entry({"admin", "system", "openmptcprouter", "interfaces_status"}, call("interfaces_status")).leaf = true
end

function wizard_add()
	local server_ip = luci.http.formvalue("server_ip")
	local shadowsocks_key = luci.http.formvalue("shadowsocks_key")
	local glorytun_key = luci.http.formvalue("glorytun_key")
	if shadowsocks_key ~= "" then
		ucic:set("shadowsocks-libev","sss0","server",server_ip)
		ucic:set("shadowsocks-libev","sss0","key",shadowsocks_key)
		ucic:set("shadowsocks-libev","sss0","method","aes-256-cfb")
		ucic:set("shadowsocks-libev","sss0","server_port","65101")
		ucic:set("shadowsocks-libev","sss0","disabled",0)
		ucic:save("shadowsocks-libev")
		ucic:commit("shadowsocks-libev")
	end
	if glorytun_key ~= "" then
		ucic:set("glorytun","vpn","host",server_ip)
		ucic:set("glorytun","vpn","port","65001")
		ucic:set("glorytun","vpn","key",glorytun_key)
		ucic:set("glorytun","vpn","enable",1)
		ucic:set("glorytun","vpn","mptcp",1)
		ucic:set("glorytun","vpn","chacha20",1)
		ucic:set("glorytun","vpn","proto","tcp")
		ucic:save("glorytun")
		ucic:commit("glorytun")
	end

	local interfaces = luci.http.formvaluetable("intf")
	for intf, _ in pairs(interfaces) do
		local ipaddr = luci.http.formvalue("cbid.network.%s.ipaddr" % intf)
		local netmask = luci.http.formvalue("cbid.network.%s.netmask" % intf)
		local gateway = luci.http.formvalue("cbid.network.%s.gateway" % intf)
		ucic:set("network",intf,"ipaddr",ipaddr)
		ucic:set("network",intf,"netmask",netmask)
		ucic:set("network",intf,"gateway",gateway)
	end
	ucic:save("network")
	ucic:commit("network")
	luci.sys.call("(env -i /bin/ubus call network reload) >/dev/null 2>/dev/null")
	luci.sys.call("/etc/init.d/glorytun restart >/dev/null 2>/dev/null")
	luci.http.redirect(luci.dispatcher.build_url("admin/system/openmptcprouter/status"))
	return
end

-- This function come from OverTheBox by OVH with very small changes
function interfaces_status()
	local ut      = require "luci.util"
	local ntm     = require "luci.model.network".init()
	local uci     = require "luci.model.uci".cursor()

	local mArray = {}

	-- OpenMPTCProuter info
	mArray.openmptcprouter = {}
	mArray.openmptcprouter["version"] = ut.trim(sys.exec("cat /etc/os-release | grep VERSION= | sed -e 's:VERSION=::'"))
	-- Check that requester is in same network
	mArray.openmptcprouter["service_addr"] = uci:get("shadowsocks", "proxy", "server") or "0.0.0.0"
	mArray.openmptcprouter["local_addr"] = uci:get("network", "lan", "ipaddr")
	mArray.openmptcprouter["wan_addr"] = "0.0.0.0"

	-- wanaddr
	mArray.openmptcprouter["wan_addr"] = sys.exec("wget -4 -qO- -T 1 http://ip.openmptcprouter.com")

	mArray.openmptcprouter["remote_addr"]        = luci.http.getenv("REMOTE_ADDR") or ""
	mArray.openmptcprouter["remote_from_lease"]        = false
	local leases=tools.dhcp_leases()
	for _, value in pairs(leases) do
		if value["ipaddr"] == mArray.openmptcprouter["remote_addr"] then
			mArray.openmptcprouter["remote_from_lease"] = true
			mArray.openmptcprouter["remote_hostname"] = value["hostname"]
		end
	end

	-- Check openmptcprouter service are running
	mArray.openmptcprouter["tun_service"] = false
	if string.find(sys.exec("/usr/bin/pgrep '^(/usr/sbin/)?glorytun(-udp)?$'"), "%d+") then
		mArray.openmptcprouter["tun_service"] = true
	end
	mArray.openmptcprouter["socks_service"] = false
	if string.find(sys.exec("/usr/bin/pgrep ss-redir"), "%d+") then
		mArray.openmptcprouter["socks_service"] = true
	end

	-- Add DHCP infos by parsing dnsmasq config file
	mArray.openmptcprouter.dhcpd = {}
	dnsmasq = ut.trim(sys.exec("cat /var/etc/dnsmasq.conf*"))
	for itf, range_start, range_end, mask, leasetime in dnsmasq:gmatch("range=[%w,!:-]*set:(%w+),(%d+\.%d+\.%d+\.%d+),(%d+\.%d+\.%d+\.%d+),(%d+\.%d+\.%d+\.%d+),(%w+)") do
		mArray.openmptcprouter.dhcpd[itf] = {}
		mArray.openmptcprouter.dhcpd[itf].interface = itf
		mArray.openmptcprouter.dhcpd[itf].range_start = range_start
		mArray.openmptcprouter.dhcpd[itf].range_end = range_end
		mArray.openmptcprouter.dhcpd[itf].netmask = mask
		mArray.openmptcprouter.dhcpd[itf].leasetime = leasetime
		mArray.openmptcprouter.dhcpd[itf].router = mArray.openmptcprouter["local_addr"]
		mArray.openmptcprouter.dhcpd[itf].dns = mArray.openmptcprouter["local_addr"]
	end
	for itf, option, value in dnsmasq:gmatch("option=(%w+),([%w:-]+),(%d+\.%d+\.%d+\.%d+)") do
		if mArray.openmptcprouter.dhcpd[itf] then
			if option == "option:router" or option == "6" then
				mArray.openmptcprouter.dhcpd[itf].router = value
			end
			if option == "option:dns-server" or option == "" then
				mArray.openmptcprouter.dhcpd[itf].dns = value
			end
		end
	end
	-- Parse mptcp kernel info
	local mptcp = {}
	local fullmesh = ut.trim(sys.exec("cat /proc/net/mptcp_fullmesh"))
	for ind, addressId, backup, ipaddr in fullmesh:gmatch("(%d+), (%d+), (%d+), (%d+\.%d+\.%d+\.%d+)") do
		mptcp[ipaddr] = {}
		mptcp[ipaddr].index = ind
		mptcp[ipaddr].id    = addressId
		mptcp[ipaddr].backup= backup
		mptcp[ipaddr].ipaddr= ipaddr
	end

	-- retrieve core temperature
	--mArray.openmptcprouter["core_temp"] = sys.exec("cat /sys/devices/platform/coretemp.0/hwmon/hwmon0/temp2_input 2>/dev/null"):match("%d+")
	mArray.openmptcprouter["loadavg"] = sys.exec("cat /proc/loadavg 2>/dev/null"):match("[%d%.]+ [%d%.]+ [%d%.]+")
	mArray.openmptcprouter["uptime"] = sys.exec("cat /proc/uptime 2>/dev/null"):match("[%d%.]+")

	-- overview status
	mArray.wans = {}
	mArray.tunnels = {}

	uci:foreach("network", "interface", function (section)
	    local interface = section[".name"]
	    local net = ntm:get_network(interface)
	    local ipaddr = net:ipaddr()
	    local gateway = section['gateway']
	    local multipath = section['multipath']

	    --if not ipaddr or not gateway then return end
	    -- Don't show if0 in the overview
	    --if interface == "lo" then return end

	    local ifname = section['ifname']
	    if multipath == "off" and not ifname:match("^tun.*") then return end

	    local asn

	    local connectivity
	    local multipath_state = ut.trim(sys.exec("multipath " .. ifname .. " | grep deactivated"))
	    if multipath_state == "" then
		    connectivity = 'OK'
	    else
		    connectivity = 'ERROR'
	    end

	    local publicIP = "-"

	    local latency = "-"

	    local data = {
		label = section['label'] or interface,
		    name = interface,
		    link = net:adminlink(),
		    ifname = ifname,
		    ipaddr = ipaddr,
		    gateway = gateway,
		    multipath = section['multipath'],
		    status = connectivity,
		    wanip = publicIP,
		    latency = latency,
		    whois = asn and asn.as_description or "unknown",
		    qos = section['trafficcontrol'],
		    download = section['download'],
		    upload = section['upload'],
	    }

	    if ifname:match("^tun.*") then
		    table.insert(mArray.tunnels, data);
	    else
		    table.insert(mArray.wans, data);
	    end
	end)

	luci.http.prepare_content("application/json")
	luci.http.write_json(mArray)
end