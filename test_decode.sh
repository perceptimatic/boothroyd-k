OPTIND=1

usage="Usage: $0 [-a INT]"
alpha=0
help="Determine the k value for a given model.
The data directory should contain either wavs + a trn file,
or wavs + corresponding txt files

Options
    -h          Display this help message and exit
    -a          alpha"

while getopts "ha:" name; do
    case $name in
        h)
            echo "$usage"
            echo ""
            echo "$help"
            exit 0;;
        a)
            alpha="$OPTARG";;
        *)
            echo -e "$usage"
            exit 1;;
    esac
done
shift "$(($OPTIND - 1))"

awk -v snr="$snr" \
'
BEGIN {
    FS = " "
}

function prob(n) {
    return int((2 ** ((-n / 16) + 2.9)) * rand())
}

{
    filename = $NF;
    NF--;
    for (i = 1; i <= NF; i++) {
        if (prob(snr) > 5) {
            $i = "q";
        }
        else if (prob(snr) > 3) {
            $i = "a ";
        }
        else if (prob(snr) > 2) {
            $i = $i " ";
        }
        else if (prob(snr) > 1) {
            $i = "";
        }
    }
    print $0, filename
}
' \
"data/boothroyd/noise/train/trn_lstm" |
awk \
'{
    filename = $NF;
    NF--;
    gsub(/ /, "");
    gsub(/_/, " ");
    print $0, filename
}' > "$spart_trn"