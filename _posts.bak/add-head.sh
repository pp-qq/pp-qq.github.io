
for post in $(find . -name '*.md')
do
    cp $in $in.bak -v
    echo '---' > $in
    echo '---' >> $in
    cat $in.bak >> $in
    rm -v $in.bak
done

