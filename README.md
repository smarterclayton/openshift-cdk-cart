# OpenShift Cartridge Development Kit

Make building and testing cartridges easy on OpenShift.  The CDK runs as a cartridge on any OpenShift server supporting downloadable cartridges (Online, Origin) and can host the builds and source code of your application.

## Installing the CDK

To get started, create a new app in OpenShift that uses the CDK cart:

    rhc create-app mycart http://cdk-claytondev.rhcloud.com/cartridge.yml
    
Once the app is created, check your cartridge source code into the Git repository.  For example, if you wanted to fork the [Go cartridge](https://github.com/smarterclayton/openshift-go-cart):

    cd mycart
    git remote add gocart git@github.com:smarterclayton/openshift-go-cart.git
    git fetch gocart
    git pull -s recursive -X theirs gocart master
    git push origin master
    
After the Git push completes you can visit your CDK app in the web, and you'll see information about your Git repository.  The CDK will automatically check for your cartridge manifest.yml or your build script.

## Creating your own cart

The best reference right now is the [cartridge writers guide](https://github.com/openshift/origin-server/blob/master/node/README.writing_cartridges.md).  More docs and tutorials should be available soon.

## Building your cart

If your cart needs to compile source into binaries in order to run on OpenShift, you'll want to execute a build. Like any other OpenShift application, your build hook is at <code>.openshift/action_hooks/build</code>. After checking in a build script and pushing your changes to the app, hit the app in the web. 

You'll see a 'Builds' section with a form.  In the form, enter the version of the cart you want to build (usually your master branch, but could be any other commit) and hit "Build Now".  The CDK will build your cart and display any output directly in the browser.  The build will be stored on disk in your app. 

Hit back and refresh the CDK page to get the latest build. Copy the build link and use it to create another app:

   rhc create-app myapp <build_link>
   
or

   rhc add-cartridge <build_link> -a myapp

If you want to debug the output of a build, SSH in to your app and run the build script manually:

    $ rhc ssh mycart
    Connecting to ....
    $ cd $OPENSHIFT_REPO_DIR
    $ .openshift/action_hooks/build

## Future Features

* Security (at a minimum BASIC auth required to do builds)
* Check your manifest for syntax errors and other common problems
* Example cart manifests for different types of carts
* Helpful scripts you can run while in the gear to debug problems or test changes
* An acceptance test suite for cartridges

Pull requests welcome!
