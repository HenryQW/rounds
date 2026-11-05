#!/bin/sh
# Prints a one-item Sparkle appcast (spec 5.8). The notes file is Markdown, which Sparkle's window shows as text.
# Usage: scripts/appcast.sh <CFBundleVersion> <short version> <DMG URL> <sign_update output> <notes file>
set -e
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Rounds</title>
    <item>
      <title>Rounds $2</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>$1</sparkle:version>
      <sparkle:shortVersionString>$2</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[
$(cat "$5")
]]></description>
      <enclosure url="$3" $4 type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
