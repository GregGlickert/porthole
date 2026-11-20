#!/bin/bash
# <swiftbar.title>Porthole</swiftbar.title>
# <swiftbar.desc>Which feature is running on which localhost port.</swiftbar.desc>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.type>streamable</swiftbar.type>
# <xbar.title>Porthole</xbar.title>
# <xbar.version>v0.1.0</xbar.version>
# <xbar.author>Greg Glickert</xbar.author>
# <xbar.author.github>GregGlickert</xbar.author.github>
# <xbar.desc>Which feature is running on which localhost port — labeled by your coding agent via MCP.</xbar.desc>
# <xbar.abouturl>https://github.com/GregGlickert/porthole</xbar.abouturl>
# Installed by scripts/install.sh, which fills in the launcher path below.
# Streamable (SwiftBar only): one long-lived process that redraws the menu when ports or labels change.
# xbar can't stream; point an xbar plugin at `porthole swiftbar` (one-shot output) instead.
# The launcher finds node at run time, so switching node versions doesn't break this plugin.
# SwiftBar's PATH is minimal; add the usual Homebrew and Docker locations so lsof/git/docker resolve.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin:$PATH"
exec "__PORTHOLE__" stream
