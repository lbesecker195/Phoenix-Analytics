# transport

How a beacon leaves the building.

[`http.ex`](http.ex) is the default and posts with `:httpc`. That choice is
deliberate: this library installs into applications that did not ask for an HTTP
client and may already carry a conflicting version of one. `:httpc` ships with
Erlang, so the dependency list stays at `plug` and `jason`.

The interesting work here is not the POST. It is that the beacon originates on
the server rather than in the visitor's browser, which means the collect
endpoint would otherwise geolocate every visit to whatever data centre the
application runs in. So the visitor's address travels as `x-forwarded-for` and
their CDN geolocation headers — Cloudflare, Vercel, CloudFront, Netlify and the
generic `x-geo-*` set — are copied across verbatim. That restores the endpoint
to the position the browser tag would have put it in.

Whether that forwarded address is believed is not decided here. The endpoint
applies its own proxy policy and only trusts the header when its deployment says
it sits behind a proxy. Without that, visits still record, geolocated to the
application's own address.

The behaviour in [`../transport.ex`](../transport.ex) exists so tests can assert
on what would have been sent, and so a host application that already runs a
client can supply its own.

Related: [privacy-first web analytics](https://seriouslysimpleanalytics.com/)
and how it
[handles addresses and geolocation](https://seriouslysimpleanalytics.com/ai-crawler-analytics).
