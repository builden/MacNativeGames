# Shared local users

On macOS, supported games use one local user list. Tomodachi Life and the native runtime builds for Tears of the Kingdom,
Breath of the Wild, Donkey Kong Bananza, and Pokémon Pokopia are connected. Other games with separate runtimes are not
connected yet; Animal Crossing: New Horizons has its own save behavior and is not part of this user list.

## Users and saves

- The shared list is `~/Library/Application Support/MacNativeGames/Accounts/users.plist`.
- There can be up to **8 active users**. The initial user is **Local** and cannot be removed.
- New users have the same ID and name in connected games. **Local** keeps each game's existing identity so old saves
  continue to open. This means the Local ID can differ by game.
- Saves remain separate by game and user. Each title keeps its own profile and save data; sharing a user does not share
  an island or save between games.

## Choosing and managing users

- With one active user, a game starts without a chooser. With several, choose a user before launch. Zelda builds open
  with the profile's saved choice; Tomodachi currently opens with **Local** selected.
- The settings panel shows the user active for this run and opens the shared user manager. The running game keeps that
  user until it exits; choosing another user takes effect on a later launch.
- Add, remove, and restore users in the manager. Removing a user archives it from the active list; it does not delete
  that user's saves, and the user can be restored later. The default Local user cannot be removed.

## Existing data and platform scope

- On first access, the shared list imports additional users from existing Zelda `users.txt` files. Their game profiles
  and saves remain in place. Zelda continues to maintain its per-game `users.txt` as a compatibility file for save tools.
- A user's game save is not deleted when that user is archived.
- The shared selector and manager are macOS features. The separate iOS account path is unchanged.

The shared store and per-game save mapping are exercised by `games/common/tests/test_users.py`. Tomodachi's settings
test checks that the current user is shown in the panel.
