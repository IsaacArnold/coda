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
