mkdir -p "data/boothroyd/test_trns"
spart_trn="data/boothroyd/test_trns/snr$snr.trn"

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