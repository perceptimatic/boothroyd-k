mkdir -p "data/boothroyd/test_trns"
spart_trn="data/boothroyd/test_trns/snr$snr.trn"

awk -v snr="$snr" \
'
BEGIN {
    FS = " "
}

function prob(n) {
    return int((4 ** ((-n / 10))) * rand())
}

{
    filename = $NF;
    NF--;
    for (i = 1; i <= NF; i++) {
        if (prob(snr) > 1) {
            $i = "q";
        }
    }
    print $0, filename
}
' \
"data/boothroyd/noise/k_test/trn_lstm" |
awk \
'{
    filename = $NF;
    NF--;
    gsub(/ /, "");
    gsub(/_/, " ");
    print $0, filename
}' > "$spart_trn"