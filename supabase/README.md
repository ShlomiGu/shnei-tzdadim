# קוד השרת (Supabase)

הקוד שרץ בפרויקט `yexzrxygjzzgsweiaqcm`, כפי שהוא פרוס בפועל.

- `migrations/` – כל השינויים במסד הנתונים לפי הסדר (טבלאות, פונקציות RPC, הרשאות, תזמונים).
- `functions/` – ה-Edge Functions. `ai-plan` (עריכת לו״ז ומשימות במילים), `push-send` (התראות), `invite` (קישורי הזמנה), `purge` (ניקוי יומי), ו-`selftest*` (בדיקות מקצה לקצה).
- `config.toml` – לכל פונקציה, אם היא דורשת JWT.

## AI
`ai-plan` משתמשת ב-Claude Haiku 5.5 כברירת מחדל (זול ומהיר). אפשר להחליף מודל בלי שינוי קוד עם הסוד `AI_MODEL`.
צריך שיהיה מוגדר הסוד `ANTHROPIC_API_KEY` (או `OPENAI_API_KEY`), אחרת האפליקציה מציגה "ה-AI עוד לא מחובר לשרת".
כל קריאה כותבת ללוג של הפונקציה שורה `{"ai":"usage",...}` עם המודל ומספר הטוקנים.

## פריסה
```
supabase functions deploy ai-plan --project-ref yexzrxygjzzgsweiaqcm
```
שינויים במסד נתונים: קובץ חדש ב-`migrations/` ואז `supabase db push`.
אחרי כל שינוי שנעשה ישירות בלוח הבקרה, כדאי לעדכן גם כאן כדי שהמאגר יישאר זהה למה שרץ.
