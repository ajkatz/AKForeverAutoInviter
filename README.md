# AKForeverAutoInviter

Invites whoever says your keyword. For WoW: Forever.

`/autoinv` opens the window; `/autoinv on` starts inviting on this character (each character starts **off**).

## The rules

| Rule | Default | Command |
|---|---|---|
| Keywords | `inv`, `invite` - the whole line, case and punctuation aside | `/autoinv keywords inv, 123` |
| ... anywhere in a line | off (`can you inv me` does not count) | `/autoinv anywhere on` |
| Heard in | whispers only | `/autoinv listen guild\|say\|channel\|whisper on\|off` |
| Classes | every class | `/autoinv class rogue off`, `/autoinv class all` |
| Class caps | none | `/autoinv max 6` (no more than 6 of any class), `/autoinv max druid 3`, `/autoinv max druid off`, `/autoinv max off` |
| Level | any | `/autoinv level 10 20`, `/autoinv level 15` (15 and up), `/autoinv level 1` (any) |
| Only guild / friends | anyone | `/autoinv only guild\|friends\|both\|none` |
| Party -> raid | off | `/autoinv raid full` (only to invite a sixth), `/autoinv raid always` (any party you lead), `/autoinv raid off` |
| Raid assistant | nobody | `/autoinv promote all on`, or a list: `/autoinv promote add Name`, `promote remove Name`, `promote clear` |

Guild covers officer chat; say covers yell; channels are every public channel (General, Trade, LFG, custom).
The rules are shared by all your characters; on/off and the window's place are per character.

Class caps count everyone in your group - you too - and everyone invited in the last two minutes who has
not joined yet, so a rush of whispers cannot go past the cap. A class's own cap wins over "of each".

Raid assistants: only a raid has them, and only its leader hands them out. "Everyone" switches on the raid's
own everyone-is-assistant setting (and back off when you untick it); the list promotes each listed name as
they join, however they got there. Both, and `raid always`, work even when this character is not inviting.

## How a stranger's level is found

The client tells an addon a whisperer's **class** (from the whisper itself) but not their **level**. Guild
members and friends are looked up in the roster and the friends list, instantly. Anyone else needs a `/who`,
and this client allows a `/who` only on a key press - so the addon sends it on **your next key press**
(any key; the key still does what it always does). The answer is read from the chat and kept out of your
chat window. A request waits two minutes for a key press, so nobody is invited while you are AFK.

With every class allowed and no level range, nothing needs looking up: the invite goes out the moment the
line arrives.

## What it cannot do

An addon may not chat on its own on this realm, so it cannot whisper back "sorry, wrong level". It says in
your own chat whom it invited, and why it skipped someone who whispered you. `/autoinv log` lists the last ten
decisions; the window shows the last six.

`/autoinv diag` writes a report into the saved file (`WTF\...\SavedVariables\AKForeverAutoInviter.lua`).
