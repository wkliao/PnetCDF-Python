
cd docs
make singlehtml
rm -rf _static
mv -f build/singlehtml/{.,}* .
touch .nojekyll