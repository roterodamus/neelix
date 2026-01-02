if status is-interactive
    # Commands to run in interactive sessions can go here
end

function fish_greeting
end

set -x SUDO_EDITOR /usr/bin/helix
set -x EDITOR /usr/bin/helix
set -x NEWT_COLORS "root=white,black \
        border=black,lightgray \
        window=lightgray,lightgray \
        shadow=black,gray \
        title=black,lightgray \
        button=black,gray \
        actbutton=black,lightgray \
        compactbutton=black,lightgray \
        checkbox=black,lightgray \
        actcheckbox=lightgray,black \
        entry=black,lightgray \
        disentry=gray,lightgray \
        label=black,lightgray \
        listbox=black,lightgray \
        actlistbox=black,white \
        sellistbox=lightgray,black \
        actsellistbox=lightgray,black \
        textbox=black,lightgray \
        acttextbox=black,white \
        emptyscale=,gray \
        fullscale=,white \
        helpline=white,black \
        roottext=lightgrey,black"
