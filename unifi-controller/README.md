# UniFi Controller on OpenWrt using Podman

The UniFi Controller is now called UniFi Network Application.

There are plenty of ways to install it on Debian/Ubuntu based Linuxes. However, on OpenWrt it's a bit more difficult, since it requires Java.
Docker/Podman to the rescue. There is an image maintained by Linuxserver group at https://github.com/linuxserver/docker-unifi-network-application.

Here's how to use it.

## Why no Docker?

First of all there are many articles and forum discussions on the Internet about Docker breaking the networking on the OpenWrt host. So I was a bit careful already. It seemed to be related to [bridge firewalling being enabled](https://forum.openwrt.org/t/openwrt-with-the-unifi-controller/128789/10) in `/etc/sysctl.d/*`.

Then there were similar discussions and observations about Docker containers being available on all interface, even the WAN interface. While there is still the firewall in place, this didn't seem very trustworthy.

Finally the Docker packages are quite huge. Even though there is plenty of space on my OpenWrt router's disk, I wanted to keep everything as slim as possible.

So I decided to give Podman a try, because it looked way slimmer.

## Podman setup

I basically followed the instructions from the OpenWrt Wiki: https://openwrt.org/docs/guide-user/virtualization/docker_host#podman

Firewall zone forwarding as well as traffic rules were adapted a little bit according to my needs.

After installing the packages, you can check the podman config defaults in `/etc/containers/`

By default, podman would put images and containers to /var, which is in RAM! So it is important to configure a non-default storage on a hard drive, as described in the Container storage (optional) section of the Wiki page above. In short:

Create custom dir:
```
mkdir -p /opt/podman/storage
```

And edit your /etc/containers/storage.conf:
```
graphroot = "/opt/podman/storage"
```

Don't forget to enable the service to make sure it's started at boot:
```
/etc/init.d/podman enable
```

That's pretty much it.

## Setup Pods and Containers

Recent versions of the UniFi Controller require a separate MongoDB.

The MongoDB container has to be initialised on first start only by providing username and password.

The UniFi application then needs the MongoDB connection parameters (including username and password) on first start, too.

For subsequent starts, these parameters do not need to be set anymore.

That's why the first start looks a bit different.

### Prepare for first start

We store the MongoDB database as well as the UniFi application config data on the host volume. Create corresponding directories first:

```
mkdir -p /opt/unifi-controller/mongodb-data
mkdir -p /opt/unifi-controller/unifi-data
```

Define MongoDB username and password:

```
export MONGO_USERNAME=unifi
export MONGO_PASSWORD=unifi
```
Please set a proper password. Depending on your firewall settings the UniFi controller application might be accessible by anybody in your lan zone. Also it's a bit safer in case something gets wrong and the database is accessible from other zones (e.g. from the WAN).

Now create a podman pod (and set the `--ip` parameter according to your needs):

```
podman pod create \
        --replace \
        --name unifi \
        --ip 10.0.0.99 \
        --restart unless-stopped
```

Then we create the MongoDB container. We use the defined username and password as the MongoDB root username and password. While there is the possibility to create a separate user with less privileges on the MongoDB, this procedure is quite cumbersome (using init scripts injected into the MongoDB container) and does not really bring any advantages, as long as you use this MongoDB container as database for the UniFi application only.

Depending on your CPU, you might need to use an older version of MongoDB (<= 4.4). Newer versions (>4.4) require a CPU with AVX support. Make sure to pin to a particular version and don't use the `:latest` tag.

```
podman create \
        --name mongodb \
        --pod unifi \
        --replace \
        --volume /opt/unifi-controller/mongodb-data/:/data/db \
        --env MONGO_INITDB_ROOT_USERNAME=$MONGO_USERNAME \
        --env MONGO_INITDB_ROOT_PASSWORD=$MONGO_PASSWORD \
        mongo:4.4
```

Then we create the UniFi application for the initial launch.

- Adapt the MONGO_* parameters if necessary for your particular case.
- `MONGO_HOST` should most likely stay set to `localhost`, since we are going to run both containers (MongoDB and UniFi controller) in a pod later. Containers within a podman pod can access each other using localhost.
- The `MONGO_AUTHSOURCE` is the MongoDB authentication database (`admin` by default).
- To avoid any permissions issues with the files on the filesystem, we set the user for the commands in the container to uid/gid 0. Since the default user on OpenWrt is the root user, too, this should not be a big problem.

```
podman create \
        --name controller \
        --pod unifi \
        --replace \
        --volume /opt/unifi-controller/unifi-data/:/config \
        --requires mongodb \
        --env PUID=0 \
        --env PGID=0 \
        --env TZ=Etc/UTC \
        --env MEM_LIMIT=1024 \
        --env MONGO_USER=$MONGO_USERNAME \
        --env MONGO_PASS=$MONGO_PASSWORD \
        --env MONGO_HOST=localhost \
        --env MONGO_PORT=27017 \
        --env MONGO_DBNAME=unifi \
        --env MONGO_AUTHSOURCE=admin \
        lscr.io/linuxserver/unifi-network-application:latest
```

Start the pod:

```
podman pod start unifi
```

Now check the logs of the first startup:

```
podman pod logs unifi       # All logs from beginning until now
podman pod logs -f unifi    # All logs from beginning and live logs
```

If you see that both MongoDB and UniFi application have started (i.e. no more movement in the logs), you can stop the pod

```
podman pod stop unifi
```

Now remove the containers:
```
podman rm controller
podman rm mongodb
```

And create them again. This time withouth the database credentials and connection details. This way we don't keep this information in the container metadata.

```
podman create \
        --name mongodb \
        --pod unifi \
        --replace \
        --volume /opt/unifi-controller/mongodb-data/:/data/db \
        mongo:4.4
```
```
podman create \
        --name controller \
        --pod unifi \
        --replace \
        --volume /opt/unifi-controller/unifi-data/:/config \
        --requires mongodb \
        --env PUID=0 \
        --env PGID=0 \
        --env TZ=Etc/UTC \
        --env MEM_LIMIT=1024 \
        lscr.io/linuxserver/unifi-network-application:latest
```

That's it.

### Subsequent start

Now you can start the pod again:

```
podman pod start unifi
```

You can access the application in the browser:

```
https://[Configured-Pod-IP]:8443
```

If it cannot be accessed, check the logs (see above) and double-check your firewall settings (zone settings as well as traffic rules).

After a restart of the router, the pods (with its 2 containers) should start automatically again.
