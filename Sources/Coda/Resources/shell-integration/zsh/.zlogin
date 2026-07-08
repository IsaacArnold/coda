# Coda shell integration — chain the user's .zlogin (login shells).
if [[ -f ${CODA_USER_ZDOTDIR:-$HOME}/.zlogin ]]; then
	CODA_ZDOTDIR=$ZDOTDIR
	ZDOTDIR=${CODA_USER_ZDOTDIR:-$HOME}
	. "${CODA_USER_ZDOTDIR:-$HOME}/.zlogin"
	CODA_USER_ZDOTDIR=$ZDOTDIR
	ZDOTDIR=$CODA_ZDOTDIR
fi
