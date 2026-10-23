# Listing text - AKForeverAutoInviter

**Summary (one line):** Invites whoever says your keyword - in a whisper, guild chat, say/yell or a public channel - limited to the classes and levels you pick, or to your guild and friends; makes the party a raid and hands out raid assistant if you like.

## Description

**Auto Inviter** - for WoW: Forever.

Say the word, get the invite. Set a keyword (`inv` and `invite` to start with), switch it on, and whoever
says it is invited - no clicking, no typing names.

- **Where it listens is up to you.** Whispers by default; guild and officer chat, say and yell, and public
  channels (General, Trade, LFG, your own) each with their own switch. The keyword counts on its own, or - if
  you like - anywhere in a line.
- **Only the classes you want.** Untick a class and nobody of it is invited.
- **Only the levels you want.** A range, or just a floor. Guild members and friends are checked on the spot;
  for anyone else the addon asks the server with a `/who` on your next key press (the game allows a `/who` only
  then), keeps its answer out of your chat, and invites them if they fit. Away from the keyboard? Nobody is
  invited behind your back - a request waits two minutes, then is let go.
- **Only your guild, your friends, or both.** Or anyone.
- **Raids.** Make a full party a raid when a sixth asks - or any party you lead, at once.
- **Raid assistant** for everyone, or just for the names on your list, however they joined.
- **Never in your way.** It invites only when you lead (or are on your own), skips whoever is already in your
  group, and tells you in your chat whom it invited - and why it passed on someone who whispered you.

Every setting is in one small window (`/autoinv`). The rules are shared by all your characters; each character
starts switched off.

## Commands

`/autoinv` opens the window.

- `/autoinv on`, `/autoinv off`, `/autoinv status`
- `/autoinv keywords inv, 123`, `/autoinv anywhere on|off`
- `/autoinv listen whisper|guild|say|channel on|off`
- `/autoinv class rogue off`, `/autoinv class all`
- `/autoinv level 10 20`, `/autoinv level 15`, `/autoinv level 1`
- `/autoinv only guild|friends|both|none`
- `/autoinv raid full|always|off`
- `/autoinv promote all on|off`, `/autoinv promote add <name>`, `promote remove <name>`, `promote clear`
- `/autoinv log`, `/autoinv diag`

## Community

Questions, bugs, ideas: the AK Addons Discord - https://discord.gg/cFvvvHVm4J - or the comments here.

Source: https://github.com/ajkatz/AKForeverAutoInviter
