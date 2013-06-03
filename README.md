# OpenShift Cartridge Development Kit

Make building and testing cartridges easy on OpenShift.  The CDK runs as a cartridge on any OpenShift server supporting downloadable cartridges (Online, Origin) and can host the builds and source code of your application.

## Installing the CDK

To get started, create a new app in OpenShift that uses the CDK cart:

    rhc create-app mycart http://cdk-claytondev.rhcloud.com
    
Once the app is created, check your cartridge source code into the Git repository.  If you want to fork an existing cartridge, just use the `--from-code` option.  For example, if you wanted to fork the [Go cartridge](https://github.com/smarterclayton/openshift-go-cart):

    rhc create-app mycart http://cdk-claytondev.rhcloud.com --from-code=git://github.com/smarterclayton/openshift-go-cart.git
    
After the create completes you can visit your CDK app in the web, and you'll see information about your Git repository.  The CDK will show info about your cart by reading your manifest.yml and build scripts.

## Creating your own cart

The best reference right now is the [cartridge writers guide](https://github.com/openshift/origin-server/blob/master/node/README.writing_cartridges.md).  More docs and tutorials should be available soon.

## Building your cart

If your cart needs to compile source into binaries in order to run on OpenShift, you'll want to execute a build. Like any other OpenShift application, your build hook is at <code>.openshift/action_hooks/build</code>. After checking in a build script and pushing your changes to the app, hit the app in the web. 

You'll see a 'Builds' section with a form.  In the form, enter the version of the cart you want to build (usually your master branch, but could be any other commit) and hit "Build Now".  

By default, the CDK generates a password for you when you install it.  This prevents people from running builds arbitrarily.  The password is stored in the gear as an environment variable - to see it run:

    $ rhc ssh mycart
    Connecting to ....
    $ echo $CDK_PASSWORD
    lotsofrandomcharacters

When prompted for your password, enter "admin" as the user and the value you printed above as your password.

The CDK will now build your cart and display any output directly in the browser.  The build will be stored on disk in your app. 

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

* Check your manifest for syntax errors and other common problems
* Example cart manifests for different types of carts
* Helpful scripts you can run while in the gear to debug problems or test changes
* An acceptance test suite for cartridges

Pull requests welcome!
