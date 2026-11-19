#!/bin/bash
# <swiftbar.title>Porthole</swiftbar.title>
# <swiftbar.desc>Which feature is running on which localhost port.</swiftbar.desc>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <xbar.title>Porthole</xbar.title>
# <xbar.version>v0.1.0</xbar.version>
# <xbar.author>Greg Glickert</xbar.author>
# <xbar.author.github>GregGlickert</xbar.author.github>
# <xbar.desc>Which feature is running on which localhost port — labeled by Claude via MCP.</xbar.desc>
# <xbar.abouturl>https://github.com/GregGlickert/porthole</xbar.abouturl>
# Installed by scripts/install.sh, which fills in NODE and CLI below.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"
NODE="__NODE__"
CLI="__CLI__"
exec "$NODE" "$CLI" swiftbar
