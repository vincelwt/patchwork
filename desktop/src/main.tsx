import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles.css";

const preventNavigation = (event: DragEvent) => event.preventDefault();
window.addEventListener("dragover", preventNavigation);
window.addEventListener("drop", preventNavigation);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
