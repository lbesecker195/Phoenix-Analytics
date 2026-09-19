# tools

The four tools every installation gets, chosen because a library with no
database can answer them honestly and without configuration.

[`list_pages.ex`](list_pages.ex) reports the pages this site serves, ranked by
how often they are asked for. A sitemap says what exists; this says what is
read, and it cannot go stale because it is built from traffic rather than
declared.

[`read_page.ex`](read_page.ex) fetches one page and returns its prose with
markup, scripts and navigation removed. An agent could fetch the URL itself, so
the value is not the fetch — it is that the page arrives readable, and that the
read joins the same visit as everything else that agent has done here. It
refuses to read the tool endpoint itself, which is a cheap loop to start by
accident.

[`site_activity.ex`](site_activity.ex) splits recent traffic into agents and
browsers. Scope is stated plainly in the result: this process, since it started.
The durable history belongs to the analytics account.

[`record_event.ex`](record_event.ex) lets an agent say what it did — finished a
task, found an answer, gave up. The server can see every request and still have
no idea whether the visit succeeded; this is the only way that gets recorded.

Related: [AI agent analytics](https://seriouslysimpleanalytics.com/ai-crawler-analytics)
and [the service](https://seriouslysimpleanalytics.com/) these report into.
