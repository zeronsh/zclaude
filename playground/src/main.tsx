import { createRoot } from 'react-dom/client';
import { App } from './app.tsx';
import './index.css';
import { connect } from './net.ts';
import { ROW_FONTS } from './rows.tsx';

// Row heights are computed from these fonts, so they must be ready before the first row.
await Promise.all(ROW_FONTS.map((font) => document.fonts.load(font).catch(() => [])));

connect();
createRoot(document.getElementById('root')!).render(<App />);
