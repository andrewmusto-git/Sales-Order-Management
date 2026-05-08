# Sample Data for Sales Order Management OAA Integration

Place representative sample data files in this directory to enable dry-run
testing without a live Oracle database connection.

## Required Sample Files

### `som_users.csv`
A CSV export of the `SOM_USER` table with at least a few rows.

Expected columns:
| Column | Description |
|---|---|
| `SOM_USER_ID` | Unique user identifier |
| `SOM_USER_NAME` | Display name |
| `SOM_USER_ACTIVE_FLAG` | Active flag — `Y` or `N` |
| `TIMESTAMP` | Last updated timestamp |
| `USERSTAMP` | Last updated by |

Example:
```csv
SOM_USER_ID,SOM_USER_NAME,SOM_USER_ACTIVE_FLAG,TIMESTAMP,USERSTAMP
JSMITH,John Smith,Y,2024-01-15 09:00:00,ADMIN
MJONES,Mary Jones,Y,2024-02-01 14:30:00,ADMIN
BWILSON,Bob Wilson,N,2023-11-10 08:00:00,ADMIN
```

---

### `som_groups.csv`
A CSV export of the `SOM_GROUP` table.

Expected columns:
| Column | Description |
|---|---|
| `SOM_GROUP_ID` | Unique group identifier |
| `SOM_GROUP_DESC` | Group description / display name |

Example:
```csv
SOM_GROUP_ID,SOM_GROUP_DESC
ORDER_ENTRY,Order Entry Clerks
ORDER_REVIEW,Order Review Managers
ADMIN,System Administrators
READONLY,Read-Only Viewers
```

---

### `som_user_group.csv`
A CSV export of the `SOM_USER_GROUP` join table.

Expected columns:
| Column | Description |
|---|---|
| `SOM_USER_ID` | User identifier (FK → SOM_USER) |
| `SOM_GROUP_ID` | Group identifier (FK → SOM_GROUP) |

Example:
```csv
SOM_USER_ID,SOM_GROUP_ID
JSMITH,ORDER_ENTRY
JSMITH,READONLY
MJONES,ORDER_REVIEW
MJONES,ORDER_ENTRY
BWILSON,ADMIN
```

---

## How to Obtain Samples

Run these queries against your Oracle instance and export the results as CSV:

```sql
-- Users
SELECT SOM_USER_ID, SOM_USER_NAME, SOM_USER_ACTIVE_FLAG, TIMESTAMP, USERSTAMP
FROM som_user
WHERE ROWNUM <= 20;

-- Groups
SELECT SOM_GROUP_ID, SOM_GROUP_DESC
FROM som_group;

-- Memberships
SELECT SOM_USER_ID, SOM_GROUP_ID
FROM som_user_group
WHERE ROWNUM <= 50;
```

> **Note:** The integration script connects directly to the Oracle database —
> these sample files are only needed for testing/dry-run scenarios without a
> live DB connection.
