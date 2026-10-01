#import <Cocoa/Cocoa.h>

/*
 * default_viewer — makes Files the file viewer macOS uses in place of
 * Finder, and puts everything back.
 *
 * While files_pref_default_viewer is on (the default), Files owns these
 * settings:
 *   NSGlobalDomain   NSFileViewer  = Files' bundle ID — "Show in Finder" /
 *                                    "Reveal in Finder" requests from other
 *                                    apps (NSWorkspace) come to Files
 *   com.apple.finder CreateDesktop = NO  — Finder draws no desktop icons
 *   com.apple.finder QuitMenuItem  = YES — Finder ▸ Quit Finder exists
 *   LaunchServices LSHandlers public.folder → Files — folders opened from
 *                                    other apps (`open ~/Downloads`, Dock
 *                                    folders, Spotlight) open in Files
 *   com.apple.archiveutility dearchive-reveal-after, archive-reveal-after
 *                                  = NO — Archive Utility opens no Finder
 *                                    window on what it creates or expands
 *                                    (set back to YES, its own default,
 *                                    rather than recorded; needs Full Disk
 *                                    Access, as Archive Utility is sandboxed)
 * The LaunchServices API rejects public.folder (paramErr), so the
 * LSHandlers entry is written directly, as ForkLift does; LaunchServices
 * reads it at login, so it (and its removal) takes effect after logging
 * out and back in.
 *
 * The first time Files changes a setting it records the value it replaced
 * (or that the key was absent). Turning the preference off writes every
 * recorded value back, relaunches Finder if its settings changed, and
 * forgets the records, leaving the system as it was before Files.
 */

/*
 * files_default_viewer_sync — applies files_pref_default_viewer: when on,
 * takes over (and re-checks) the settings above, quitting Finder if its
 * settings changed so they take effect; when off, restores the recorded
 * originals. Idempotent and cheap when nothing differs, so it runs at every
 * launch and after the preference changes. Work runs on a private serial
 * queue.
 *
 * Inputs:
 *   done — called on the main queue with YES if every setting now matches
 *          the preference, NO if a preference write failed (records are
 *          then kept so a later sync can retry). May be nil.
 */
void files_default_viewer_sync(void (^done)(BOOL ok));

/*
 * files_default_viewer_choose — makes Files (files = YES) or Finder the
 * default file viewer, for the Preferences ▸ Integration "Set default file
 * browser to …" buttons. Choosing Finder asks for confirmation, then turns
 * files_pref_default_viewer off (which writes back every setting Files
 * replaced and turns Archive Utility's reveal-in-Finder back on); choosing
 * Files reverses it. Runs even when the choice is
 * already in effect, re-checking and repairing every setting.
 *
 * Every step is logged — the setting, its value before and after, the
 * equivalent Terminal command (or that none was needed), and whether the
 * value read back as wanted — to
 * ~/Library/Logs/Files/default-file-browser-<date>.log, which is then
 * opened; a summary at the end lists every check with the command that
 * shows it. If a check failed an alert also says so. Main thread only.
 *
 * Inputs:
 *   files    — YES for Files, NO for Finder
 *   window   — window for the alert sheets; nil = app-modal alerts
 *   finished — called on the main queue once the choice was applied (its
 *              log opened) or cancelled; may be nil
 */
void files_default_viewer_choose(BOOL files, NSWindow *window, void (^finished)(void));
