# scripts iniciais

kodix() {
    if [ -z "$1" ]; then
        echo "kodix nome"
        return 1
    fi
    wget https://raw.githubusercontent.com/kodishmediacenter/kodix/refs/heads/main/$1.sh 
    clear	
    sh $1.sh	
}

nyaa() {
    if [[ -z "$1" ]]; then
        echo "Use: nyaa CODIGO"
        return 1
    fi

    flatpak run com.stremio.Stremio "https://nyaa.si/download/${1}.torrent"
}
