# Coda shell integration — chain the user's .zprofile (login shells).
if [[ -f ${CODA_USER_ZDOTDIR:-$HOME}/.zprofile ]]; then
	CODA_ZDOTDIR=$ZDOTDIR
	ZDOTDIR=${CODA_USER_ZDOTDIR:-$HOME}
	. "${CODA_USER_ZDOTDIR:-$HOME}/.zprofile"
	CODA_USER_ZDOTDIR=$ZDOTDIR
	ZDOTDIR=$CODA_ZDOTDIR
fi
