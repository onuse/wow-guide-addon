# Guide

A World of Warcraft 3.3.5a addon for one private realm: directions from
Claude, the realm's resident game master. Claude can point an arrow at a
spot, a creature, a list of places or a hunt, and Guide shows it: a compass
outdoors, a route through the corridors inside dungeons, stars on the
minimap for the rest. It also has a small panel for Claude's notes, a `/way`
command and a movable coordinate box.

Inside the old dungeons and raids (levels 1-60), where the game's own map
shows only the zone outside, Guide draws its own map when you press M: the
dungeon's real floors seen from above, you and your group on it, the bosses
(greyed once dead), and a stack of slabs where floors lie on top of each
other. Click the ground or a boss and the arrow leads you there.

Guide only listens to messages from Claude on its own realm. On any other
server it does nothing.

## Install

1. Download the newest `Guide-<version>.zip` from
   [Releases](https://github.com/onuse/wow-guide-addon/releases).
2. Unzip it into `World of Warcraft/Interface/AddOns/`, so that you have
   `Interface/AddOns/Guide/Guide.toc`.
3. Restart the game, or log out to the character screen and back in.

The realm notices which version you run and tells you when a newer one is out.

## For developers

The server side is `src/server/scripts/Custom/guide.cpp` in the realm's
AzerothCore fork (`.guide point|npc|hunt|object|pins|stop|test|release`). It
sends hidden addon whispers from the character Claude. The wire format and
design notes are at the top of both files.

`tools/publish.sh` publishes the version in `Guide/Guide.lua`: a folder on the
realm's home share, a zip on its downloads page, and a GitHub release with the
same zip. A published version is never changed; a fix is a new version.

The dungeon maps (`Guide/maps/*.blp`, `Guide/DungeonMaps.lua`) are drawn by
`tools/make_dungeon_maps.py` from the server's navmesh and the client's own
building and terrain textures (`tools/materials.py`, `tools/navmesh.py`,
`tools/blp.py`); `--web` also writes the monitor's guide-page copies.
