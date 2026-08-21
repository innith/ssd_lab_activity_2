DROP TABLE IF EXISTS staging_eventlog;

CREATE TABLE staging_eventlog (
    OrderRequestorID VARCHAR(20)   NOT NULL, 
    OrderID          VARCHAR(20)   NOT NULL,  
    PartnerID        VARCHAR(50)   NOT NULL DEFAULT '', 
    PINCode          VARCHAR(10)   NOT NULL,
    Status           VARCHAR(50)   NOT NULL,
    `Timestamp`      DATETIME      NOT NULL,
    INDEX idx_orderid_ts (OrderID, `Timestamp`),
    INDEX idx_status (Status),
    INDEX idx_requestor (OrderRequestorID)
);

LOAD DATA LOCAL INFILE  'C:/ssdlab2_resources/delivery_data_100k_expanded_pins.csv'
INTO TABLE staging_eventlog
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS
(OrderRequestorID, OrderID, PartnerID, PINCode, Status, `Timestamp`);


DROP TABLE IF EXISTS deliverystatistics;

CREATE TABLE deliverystatistics (
    PINCode                 VARCHAR(10)     NOT NULL,
    PartnerID                VARCHAR(50)     NOT NULL,
    MonthofOrder             TINYINT UNSIGNED NOT NULL,
    YearofOrder               SMALLINT UNSIGNED NOT NULL,

    TotalOrders               INT DEFAULT 0,
    TotalPendingAssignment    INT DEFAULT 0,
    TotalAccepted              INT DEFAULT 0,
    TotalHeadingforPickup      INT DEFAULT 0,
    TotalArrivedatPickup       INT DEFAULT 0,
    TotalPickedUp        INT DEFAULT 0,
    TotalOutforDelivery    INT DEFAULT 0,
    TotalArrivedatDoorStep  INT DEFAULT 0,
    TotalDelivered INT DEFAULT 0,
    TotalDropped     INT DEFAULT 0,
    TotalDelayedatPickup  INT DEFAULT 0,
    TotalDeliveryFailed   INT DEFAULT 0,
    TotalReturningtoStore   INT DEFAULT 0,
    TotalReturned   INT DEFAULT 0,
    TotalCancelled   INT DEFAULT 0,
    TimetoAccept   DECIMAL(10,2),   
    TimetoPickup    DECIMAL(10,2),  
    TimetoArriveatDoorStep  DECIMAL(10,2), 
    TimetoDeliver  DECIMAL(10,2), 

    PRIMARY KEY (PINCode, PartnerID, MonthofOrder, YearofOrder)
);


DROP PROCEDURE IF EXISTS PopulateDeliveryStatistics;

DELIMITER $$

CREATE PROCEDURE PopulateDeliveryStatistics()
BEGIN
    DECLARE done        INT DEFAULT FALSE;
    DECLARE v_orderid   VARCHAR(20);
    DECLARE v_pincode  VARCHAR(10);
    DECLARE v_partnerid   VARCHAR(50);
    DECLARE v_pending_ts  DATETIME;
    DECLARE v_month  TINYINT UNSIGNED;
    DECLARE v_year    SMALLINT UNSIGNED;
    DECLARE v_accepted_ts  DATETIME;
    DECLARE v_pickedup_ts  DATETIME;
    DECLARE v_arrived_ts   DATETIME;
    DECLARE v_delivered_ts DATETIME;

    DECLARE order_cursor CURSOR FOR
        SELECT OrderID, PINCode, PartnerID, FirstPendingTs, MonthofOrder, YearofOrder
        FROM tmp_order_keys;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    TRUNCATE TABLE deliverystatistics;
    DROP TEMPORARY TABLE IF EXISTS tmp_first_pending;
    DROP TEMPORARY TABLE IF EXISTS tmp_pincode;
    DROP TEMPORARY TABLE IF EXISTS tmp_last_partner_ts;
    DROP TEMPORARY TABLE IF EXISTS tmp_last_partner;
    DROP TEMPORARY TABLE IF EXISTS tmp_order_keys;
    DROP TEMPORARY TABLE IF EXISTS tmp_order_metrics;

    CREATE TEMPORARY TABLE tmp_first_pending AS
    SELECT OrderID, MIN(`Timestamp`) AS FirstPendingTs
    FROM staging_eventlog
    WHERE Status = 'PendingAssignment'
    GROUP BY OrderID;

    CREATE TEMPORARY TABLE tmp_pincode AS
    SELECT OrderID, MIN(PINCode) AS PINCode
    FROM staging_eventlog
    GROUP BY OrderID;

    CREATE TEMPORARY TABLE tmp_last_partner_ts AS
    SELECT OrderID, MAX(`Timestamp`) AS LastTs
    FROM staging_eventlog
    WHERE PartnerID <> ''
    GROUP BY OrderID;

    CREATE TEMPORARY TABLE tmp_last_partner AS
    SELECT t.OrderID, MIN(s.PartnerID) AS PartnerID  
    FROM tmp_last_partner_ts t
    JOIN staging_eventlog s
      ON s.OrderID = t.OrderID AND s.`Timestamp` = t.LastTs AND s.PartnerID <> ''
    GROUP BY t.OrderID;

    CREATE TEMPORARY TABLE tmp_order_keys AS
    SELECT
        p.OrderID,
        pc.PINCode,
        COALESCE(lp.PartnerID, '') AS PartnerID,
        p.FirstPendingTs,
        MONTH(p.FirstPendingTs) AS MonthofOrder,
        YEAR(p.FirstPendingTs)  AS YearofOrder
    FROM tmp_first_pending p
    JOIN tmp_pincode pc ON pc.OrderID = p.OrderID
    LEFT JOIN tmp_last_partner lp ON lp.OrderID = p.OrderID;

    CREATE TEMPORARY TABLE tmp_order_metrics (
        OrderID    VARCHAR(20) PRIMARY KEY,
        PINCode     VARCHAR(10),
        PartnerID   VARCHAR(50),
        MonthofOrder TINYINT UNSIGNED,
        YearofOrder SMALLINT UNSIGNED,
        TimetoAccept  DECIMAL(10,2),
        TimetoPickup   DECIMAL(10,2),
        TimetoArriveatDoorStep  DECIMAL(10,2),
        TimetoDeliver DECIMAL(10,2)
    );

    OPEN order_cursor;

    read_loop: LOOP
        FETCH order_cursor INTO v_orderid, v_pincode, v_partnerid, v_pending_ts, v_month, v_year;
        IF done THEN
            LEAVE read_loop;
        END IF;

        SET v_accepted_ts = (
            SELECT MIN(`Timestamp`) FROM staging_eventlog
            WHERE OrderID = v_orderid AND Status = 'Accepted' AND `Timestamp` >= v_pending_ts
        );

        SET v_pickedup_ts = NULL;
        IF v_accepted_ts IS NOT NULL THEN
            SET v_pickedup_ts = (
                SELECT MIN(`Timestamp`) FROM staging_eventlog
                WHERE OrderID = v_orderid AND Status = 'PickedUp' AND `Timestamp` >= v_accepted_ts
            );
        END IF;

        SET v_arrived_ts = NULL;
        IF v_pickedup_ts IS NOT NULL THEN
            SET v_arrived_ts = (
                SELECT MIN(`Timestamp`) FROM staging_eventlog
                WHERE OrderID = v_orderid AND Status = 'ArrivedatDoorStep' AND `Timestamp` >= v_pickedup_ts
            );
        END IF;

        SET v_delivered_ts = (
            SELECT MIN(`Timestamp`) FROM staging_eventlog
            WHERE OrderID = v_orderid AND Status = 'Delivered' AND `Timestamp` >= v_pending_ts
        );

        INSERT INTO tmp_order_metrics
        VALUES (
            v_orderid, v_pincode, v_partnerid, v_month, v_year,
            CASE WHEN v_accepted_ts IS NOT NULL
                 THEN TIMESTAMPDIFF(MINUTE, v_pending_ts, v_accepted_ts) END,
            CASE WHEN v_pickedup_ts IS NOT NULL AND v_accepted_ts IS NOT NULL
                 THEN TIMESTAMPDIFF(MINUTE, v_accepted_ts, v_pickedup_ts) END,
            CASE WHEN v_arrived_ts IS NOT NULL AND v_pickedup_ts IS NOT NULL
                 THEN TIMESTAMPDIFF(MINUTE, v_pickedup_ts, v_arrived_ts) END,
            CASE WHEN v_delivered_ts IS NOT NULL
                 THEN TIMESTAMPDIFF(MINUTE, v_pending_ts, v_delivered_ts) END
        );
    END LOOP;

    CLOSE order_cursor;

    INSERT INTO deliverystatistics (
        PINCode, PartnerID, MonthofOrder, YearofOrder,
        TotalOrders, TotalPendingAssignment, TotalAccepted, TotalHeadingforPickup,
        TotalArrivedatPickup, TotalPickedUp, TotalOutforDelivery, TotalArrivedatDoorStep,
        TotalDelivered, TotalDropped, TotalDelayedatPickup, TotalDeliveryFailed,
        TotalReturningtoStore, TotalReturned, TotalCancelled,
        TimetoAccept, TimetoPickup, TimetoArriveatDoorStep, TimetoDeliver
    )
    SELECT
        c.PINCode, c.PartnerID, c.MonthofOrder, c.YearofOrder,
        c.TotalOrders, c.TotalPendingAssignment, c.TotalAccepted, c.TotalHeadingforPickup,
        c.TotalArrivedatPickup, c.TotalPickedUp, c.TotalOutforDelivery, c.TotalArrivedatDoorStep,
        c.TotalDelivered, c.TotalDropped, c.TotalDelayedatPickup, c.TotalDeliveryFailed,
        c.TotalReturningtoStore, c.TotalReturned, c.TotalCancelled,
        t.TimetoAccept, t.TimetoPickup, t.TimetoArriveatDoorStep, t.TimetoDeliver
    FROM (
        SELECT
            k.PINCode, k.PartnerID, k.MonthofOrder, k.YearofOrder,
            COUNT(DISTINCT k.OrderID)   AS TotalOrders,
            SUM(s.Status = 'PendingAssignment')   AS TotalPendingAssignment,
            SUM(s.Status = 'Accepted')  AS TotalAccepted,
            SUM(s.Status = 'HeadingforPickup')  AS TotalHeadingforPickup,
            SUM(s.Status = 'ArrivedatPickup')   AS TotalArrivedatPickup,
            SUM(s.Status = 'PickedUp')  AS TotalPickedUp,
            SUM(s.Status = 'OutforDelivery')  AS TotalOutforDelivery,
            SUM(s.Status = 'ArrivedatDoorStep') AS TotalArrivedatDoorStep,
            SUM(s.Status = 'Delivered') AS TotalDelivered,
            SUM(s.Status = 'Dropped')  AS TotalDropped,
            SUM(s.Status = 'DelayedatPickup') AS TotalDelayedatPickup,
            SUM(s.Status = 'DeliveryFailed')  AS TotalDeliveryFailed,
            SUM(s.Status = 'ReturningtoStore') AS TotalReturningtoStore,
            SUM(s.Status = 'Returned') AS TotalReturned,
            SUM(s.Status = 'Cancelled') AS TotalCancelled
        FROM tmp_order_keys k
        JOIN staging_eventlog s ON s.OrderID = k.OrderID
        GROUP BY k.PINCode, k.PartnerID, k.MonthofOrder, k.YearofOrder
    ) c
    LEFT JOIN (
        SELECT
            PINCode, PartnerID, MonthofOrder, YearofOrder,
            AVG(TimetoAccept)    AS TimetoAccept,
            AVG(TimetoPickup)   AS TimetoPickup,
            AVG(TimetoArriveatDoorStep)   AS TimetoArriveatDoorStep,
            AVG(TimetoDeliver)    AS TimetoDeliver
        FROM tmp_order_metrics
        GROUP BY PINCode, PartnerID, MonthofOrder, YearofOrder
    ) t
      ON t.PINCode = c.PINCode AND t.PartnerID = c.PartnerID
     AND t.MonthofOrder = c.MonthofOrder AND t.YearofOrder = c.YearofOrder;

    DROP TEMPORARY TABLE IF EXISTS tmp_first_pending;
    DROP TEMPORARY TABLE IF EXISTS tmp_pincode;
    DROP TEMPORARY TABLE IF EXISTS tmp_last_partner_ts;
    DROP TEMPORARY TABLE IF EXISTS tmp_last_partner;
    DROP TEMPORARY TABLE IF EXISTS tmp_order_keys;
    DROP TEMPORARY TABLE IF EXISTS tmp_order_metrics;

END$$

DELIMITER ;

DROP TABLE IF EXISTS requestorstatistics;

CREATE TABLE requestorstatistics (
    OrderRequestorID     VARCHAR(20) PRIMARY KEY,
    TotalOrdersPlaced    INT DEFAULT 0,
    TotalDelivered     INT DEFAULT 0,
    TotalCancelled        INT DEFAULT 0,
    TotalDeliveryFailed  INT DEFAULT 0,
    CancellationRate  DECIMAL(5,2),  
    FailureRate      DECIMAL(5,2),
    AvgTimeToDeliver  DECIMAL(10,2), 
    MostUsedPIN   VARCHAR(10),
    MostFrequentPartnerID  VARCHAR(50)
);


DROP PROCEDURE IF EXISTS PopulateRequestorStatistics;

DELIMITER $$

CREATE PROCEDURE PopulateRequestorStatistics()
BEGIN
    TRUNCATE TABLE requestorstatistics;

    DROP TEMPORARY TABLE IF EXISTS tmp_req_base;
    DROP TEMPORARY TABLE IF EXISTS tmp_req_last_partner_ts;
    DROP TEMPORARY TABLE IF EXISTS tmp_req_last_partner;
    DROP TEMPORARY TABLE IF EXISTS tmp_req_orders;
    DROP TEMPORARY TABLE IF EXISTS tmp_pin_ranked;
    DROP TEMPORARY TABLE IF EXISTS tmp_partner_ranked;

    CREATE TEMPORARY TABLE tmp_req_base AS
    SELECT
        OrderRequestorID,
        OrderID,
        MIN(CASE WHEN Status = 'PendingAssignment' THEN `Timestamp` END) AS FirstPendingTs,
        MIN(CASE WHEN Status = 'Delivered'          THEN `Timestamp` END) AS DeliveredTs,
        MAX(Status = 'Cancelled')   AS IsCancelled,
        MAX(Status = 'DeliveryFailed')  AS IsFailed,
        MIN(PINCode)   AS PINCode
    FROM staging_eventlog
    GROUP BY OrderRequestorID, OrderID;

    CREATE TEMPORARY TABLE tmp_req_last_partner_ts AS
    SELECT OrderID, MAX(`Timestamp`) AS LastTs
    FROM staging_eventlog
    WHERE PartnerID <> ''
    GROUP BY OrderID;

    CREATE TEMPORARY TABLE tmp_req_last_partner AS
    SELECT t.OrderID, MIN(s.PartnerID) AS PartnerID
    FROM tmp_req_last_partner_ts t
    JOIN staging_eventlog s
      ON s.OrderID = t.OrderID AND s.`Timestamp` = t.LastTs AND s.PartnerID <> ''
    GROUP BY t.OrderID;

    CREATE TEMPORARY TABLE tmp_req_orders AS
    SELECT b.*, lp.PartnerID
    FROM tmp_req_base b
    LEFT JOIN tmp_req_last_partner lp ON lp.OrderID = b.OrderID;

    CREATE TEMPORARY TABLE tmp_pin_ranked AS
    SELECT OrderRequestorID, PINCode,
           ROW_NUMBER() OVER (PARTITION BY OrderRequestorID ORDER BY COUNT(*) DESC, PINCode) AS rn
    FROM tmp_req_orders
    GROUP BY OrderRequestorID, PINCode;

    CREATE TEMPORARY TABLE tmp_partner_ranked AS
    SELECT OrderRequestorID, PartnerID,
           ROW_NUMBER() OVER (PARTITION BY OrderRequestorID ORDER BY COUNT(*) DESC, PartnerID) AS rn
    FROM tmp_req_orders
    WHERE PartnerID IS NOT NULL AND PartnerID <> ''
    GROUP BY OrderRequestorID, PartnerID;

    INSERT INTO requestorstatistics (
        OrderRequestorID, TotalOrdersPlaced, TotalDelivered, TotalCancelled, TotalDeliveryFailed,
        CancellationRate, FailureRate, AvgTimeToDeliver, MostUsedPIN, MostFrequentPartnerID
    )
    SELECT
        o.OrderRequestorID,
        COUNT(*)         AS TotalOrdersPlaced,
        SUM(o.DeliveredTs IS NOT NULL)   AS TotalDelivered,
        SUM(o.IsCancelled) AS TotalCancelled,
        SUM(o.IsFailed)  AS TotalDeliveryFailed,
        ROUND(100 * SUM(o.IsCancelled) / COUNT(*), 2) AS CancellationRate,
        ROUND(100 * SUM(o.IsFailed) / COUNT(*), 2) AS FailureRate,
        ROUND(AVG(CASE WHEN o.DeliveredTs IS NOT NULL
                       THEN TIMESTAMPDIFF(MINUTE, o.FirstPendingTs, o.DeliveredTs) END), 2) AS AvgTimeToDeliver,
        MAX(CASE WHEN pr.rn = 1 THEN pr.PINCode END) AS MostUsedPIN,
        MAX(CASE WHEN par.rn = 1 THEN par.PartnerID END) AS MostFrequentPartnerID
    FROM tmp_req_orders o
    LEFT JOIN tmp_pin_ranked pr ON pr.OrderRequestorID = o.OrderRequestorID AND pr.rn = 1
    LEFT JOIN tmp_partner_ranked par ON par.OrderRequestorID = o.OrderRequestorID AND par.rn = 1
    GROUP BY o.OrderRequestorID;

    DROP TEMPORARY TABLE IF EXISTS tmp_req_base;
    DROP TEMPORARY TABLE IF EXISTS tmp_req_last_partner_ts;
    DROP TEMPORARY TABLE IF EXISTS tmp_req_last_partner;
    DROP TEMPORARY TABLE IF EXISTS tmp_req_orders;
    DROP TEMPORARY TABLE IF EXISTS tmp_pin_ranked;
    DROP TEMPORARY TABLE IF EXISTS tmp_partner_ranked;

END$$

DELIMITER ;
