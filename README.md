# Guide

Client addon (WoW 3.3.5a) for Jonas's realm: directions from Claude.
Install: copy `Guide/` into `World of Warcraft/Interface/AddOns/`.

The server side is `src/server/scripts/Custom/guide.cpp` in wow-server
(`.guide point|npc|stop|test`), which sends hidden addon whispers from the
character Claude. Wire format and design notes are at the top of both files.

Roadmap: 1) arrow (this), 2) a panel for Claude's answers and an "ask" box,
3) state sharing on request and live scripts from Claude (per-machine
switch), custom windows such as transmog.
