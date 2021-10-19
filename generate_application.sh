## takes environment vars from CI and puts them into an application spec
set -u

# TODO get project_name from github, allow overrides
project_name=journals
# Set to true when testing
skip_git=true

cluster_name=${TARGET_CLUSTER:-dev}

domain_name="dsrd.libraries.psu.edu"
config_env=${CONFIG_ENV:-dev}
config_branch=${CONFIG_BRANCH:-master}
image_repository=${IMAGE_REPOSITORY:-harbor.k8s.libraries.psu.edu/library/$project_name}

## configure git 
git config user.email "circle@dcircleci.com"
git config user.name "CircleCI"

## create sluggified branch
branch_slugified=$(echo $CIRCLE_BRANCH | sed -e "s/[^[:alnum:]]/-/g" | tr -s "-" | tr A-Z a-z| sed -e "s/preview-//g")
manifest="clusters/$cluster_name/manifests/$project_name/$branch_slugified.yaml"

## Here we set the customizables based off branch name. we'll do all switching based off branch name?
## TODO maybe pass these from circle?
if [ ${CIRCLE_BRANCH} == "master" ]; then
    app_name="$project_name-qa"
    dest_namespace="$app_name"
    config_env="qa"
    vault_mount_path=auth/k8s-dsrd-dev
    fqdn="$app_name.$domain_name"
    vault_path="secret/data/app/$app_name/${config_env}"
    vault_login_role="$project_name-qa"
else
    app_name="$project_name-$branch_slugified"
    dest_namespace="$app_name"
    config_env="dev"
    vault_mount_path=auth/k8s-dsrd-dev
    fqdn=$app_name.$domain_name
    vault_path="secret/data/app/$project_name/${config_env}"
    vault_login_role="$project_name-${config_env}"
fi

initalize_app=false
if [ ! -f $manifest.yaml ]; then
    initalize_app=true
    cp template.yaml $manifest.yaml
fi

# Turn the block into yaml before proccessing
sed -i -e 's/^\([[:space:]]*\)values: |/\1values:/g' $manifest.yaml

function initalize_app {
    yq w $manifest.yaml metadata.name $app_name -i
    yq w $manifest.yaml spec.destination.namespace $dest_namespace -i
    yq w $manifest.yaml spec.source.helm.values.ingress.hosts.[+].host $fqdn -i
    yq w $manifest.yaml spec.source.helm.values.image.tag $CIRCLE_SHA1 -i
}

function update_app {
    yq w $manifest.yaml spec.source.helm.values.image.tag $CIRCLE_SHA1 -i
    yq w $manifest.yaml spec.source.helm.values.image.repository $image_repository -i
}

## we only update the image tag if the file has been copied.
if [ "$initalize_app" = true ]; then 
    initalize_app
else
    update_app
fi

# Turn the yaml into a block for helm values
sed -i -e 's/[[:space:]]values:/values: |/g' $manifest.yaml

if [ "$skip_git" = true ]; then 
  echo "not pushing the file to git"
else
    ## add the file to git, and push it up 
    git add $manifest.yaml
    added=$(git status --porcelain=v1| grep "^A\|^M")
    git checkout $config_branch
    if [[ $added ]]; then
        git commit -m "Adds deployment for $branch_slugified. Circle Build Number: $CIRCLE_BUILD_NUM"
        git push -u origin $config_branch
    else
        echo "No files added. Continuing"
    fi
fi
