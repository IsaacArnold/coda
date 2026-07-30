# Coda shell integration — opt out of third-party shell-pty wrappers.
#
# kiro-cli / Amazon Q (and Fig before them) hook the user's dotfiles and, unless already inside
# their own pty, `exec` that pty wrapper over the shell. Because ~/.zprofile and ~/.zshrc are
# chained BELOW — before this wrapper reaches its .zshrc, the only place the OSC 133 hooks are
# installed — that exec replaces the process while our integration is half-loaded, and the shell
# the wrapper then spawns does not inherit ZDOTDIR. The result is a shell permanently outside
# Coda's integration: no prompt markers, and completions that silently never appear.
#
# Their launch gate is `[[ -z $Q_TERM ]]` (plus a $Q_TERM_TMUX branch when inside tmux); the value
# is only ever tested for emptiness, never parsed. Claiming the slot here — before any user
# dotfile is sourced — makes them skip the exec and stay a plain set of shell hooks, which coexist
# fine. Their inline autocomplete is inactive inside Coda by design: Coda supplies its own popup,
# and two completion UIs driving one line editor fight each other.
#
# Regression-tested end-to-end by `ShellIntegrationWrapperTests`.
export Q_TERM=coda Q_TERM_TMUX=coda
export FIG_TERM=coda FIG_TERM_TMUX=coda

# Coda shell integration — chain the user's .zshenv without shadowing it.
# Runs first for every zsh; ZDOTDIR currently points at Coda's bundle dir.
if [[ -f ${CODA_USER_ZDOTDIR:-$HOME}/.zshenv ]]; then
	CODA_ZDOTDIR=$ZDOTDIR
	ZDOTDIR=${CODA_USER_ZDOTDIR:-$HOME}
	. "${CODA_USER_ZDOTDIR:-$HOME}/.zshenv"
	# The user's .zshenv may itself change ZDOTDIR; re-capture, then restore ours.
	CODA_USER_ZDOTDIR=$ZDOTDIR
	ZDOTDIR=$CODA_ZDOTDIR
fi
