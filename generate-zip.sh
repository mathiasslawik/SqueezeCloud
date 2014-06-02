set -x
cd ..
zip -r SqueezeCloud SqueezeCloud -x \*.zip \*.sh \*.git\* \*README\* \*webauth\*
cd SqueezeCloud

VERSION=$(grep \<version\> install.xml  | perl -n -e '/>(.*)</; print $1;')
SHA=$(shasum SqueezeCloud.zip | awk '{print $1;}')

cat <<EOF > ../public.xml
<extensions>
	<details>
		<title lang="EN">SqueezeCloud Plugin</title>
	</details>
	<plugins>
		<plugin name="SqueezeCloud" version="$VERSION" minTarget="7.5" maxTarget="*">
			<title lang="EN">SqueezeCloud</title>
			<desc lang="EN">Browse, search and play urls from soundcloud</desc>
			<url>http://danielvijge.github.io/SqueezeCloud/SqueezeCloud.zip</url>
			<link>https://github.com/danielvijge/SqueezeCloud</link>
			<sha>$SHA</sha>
			<creator>Daniel Vijge, Robert Gibbon, David Blackman</creator>
		</plugin>
	</plugins>
</extensions>
EOF

