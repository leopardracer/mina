/*
  Challenges.re has the responsibilities of taking a Map of public keys to
  metricRecords and compute a new Map that contains a public key to
  points where points is a number value (either Int64 or int).

  Points are rewarded based on completing challenges that are previously defined
  by O(1) community managers. The challenges that are supported are defined in
  calculatePoints()

  The data visualized for a Map is as follows, where x is some number value:

  "public_key1": x

   All the challenges to be computed are specified in calculatePoints().
   calculatePoints() is invoked in Upload.re where the points are computed
   and then uploaded to the Leaderboard Google Sheets.
 */

module StringMap = Map.Make(String);

let echoServiceChallenge = metricsMap => {
  metricsMap
  |> Points.addPointsToUsersWithAtleastN(
       (metricRecord: Types.Metrics.t) =>
         metricRecord.transactionsReceivedByEcho,
       1,
       1000,
     );
};

let coinbaseReceiverChallenge = (points, metricsMap) => {
  metricsMap
  |> StringMap.fold(
       (key, metric: Types.Metrics.t, map) => {
         switch (metric.coinbaseReceiver) {
         | Some(metricValue) =>
           metricValue ? StringMap.add(key, points, map) : map
         | None => map
         }
       },
       StringMap.empty,
     );
};

let snarkFeeChallenge = metricsMap => {
  Points.applyTopNPoints(
    [|
      (0, 6500), // 1st place: 6500 pts
      (1, 5000), // 2nd place: 5000 pts
      (2, 4000), // 3rd place: 4000 pts
      (11, 3000), // Top 10: 3000 pts.
      (21, 1500), // Top 20: 2500 pts
      (101, 1500), // Top 100: 1500 pts
      (201, 1000) // Top 200: 1000 pts
    |],
    metricsMap,
    (metricRecord: Types.Metrics.t) => metricRecord.snarkFeesCollected,
    compare,
  );
};

let blocksChallenge = metricsMap => {
  Points.applyTopNPoints(
    [|
      (0, 6500), // 1st place: 6500 pts
      (1, 5000), // 2nd place: 5000 pts
      (2, 4000), // 3rd place: 4000 pts
      (11, 3000), // Top 10: 3000 pts.
      (21, 2500), // Top 20: 2500 pts
      (101, 1500), // Top 100: 1500 pts
      (201, 100) // Top 200: 1000 pts
    |],
    metricsMap,
    (metricRecord: Types.Metrics.t) => metricRecord.blocksCreated,
    compare,
  );
};

let sendMinaChallenge = metricsMap => {
  Points.applyTopNPoints(
    [|
      (0, 6500), // 1st place: 6500 pts
      (1, 5000), // 2nd place: 5000 pts
      (2, 4000), // 3rd place: 4000 pts
      (11, 3000), // Top 10: 3000 pts.
      (21, 2500), // Top 20: 2500 pts
      (101, 1500), // Top 100: 1500 pts
      (201, 1000) // Top 200: 1000 pts
    |],
    metricsMap,
    (metricRecord: Types.Metrics.t) => metricRecord.transactionSent,
    compare,
  );
};

let createAndSendTokenChallenge = metricsMap => {
  [
    // you will receive 1000 pts for minting and sending your own token to another account
    Points.addPointsToUsersWithAtleastN(
      (metricRecord: Types.Metrics.t) => metricRecord.createAndSendToken,
      1,
      1000,
      metricsMap,
    ),
  ]
  |> Points.sumPointsMaps;
};

let calculatePoints = (challengeName, metricsMap) => {
  switch (String.lowercase_ascii(challengeName)) {
  | "produce blocks on mina" => Some(blocksChallenge(metricsMap))
  /*
     This challenge will be calculated close to the end of the testnet
   | "snarking on mina" => Some(snarkFeeChallenge(metricsMap))
   */
  | "send mina" => Some(sendMinaChallenge(metricsMap))
  | _ => None
  };
};
