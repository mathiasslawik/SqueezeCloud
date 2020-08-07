#!/bin/sh
set -x

VERSION=`git describe --tags`

sed "s/{{ env\['VERSION'\] }}/$VERSION/g" install.template.xml > install.xml
zip -r SqueezeCloud-$VERSION.zip . -x \*.zip \*.sh \*.git\* \*README\* \*webauth\* \*.sublime\* \*.DS_Store\* \*.editorconfig \*.template.xml
rm install.xml
