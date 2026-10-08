# ── Étape 1 : build ─────────────────────────────────────────────────────────
# TODO 1 : image de build (Maven + JDK 21)
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

# TODO 2 : copier le pom.xml SEUL, puis télécharger les dépendances (mise en cache)
COPY pom.xml ./
RUN mvn -q -B dependency:go-offline

# TODO 3 : copier les sources, puis compiler SANS lancer les tests
COPY src ./src
RUN mvn -q -B package -DskipTests

# ── Étape 2 : image finale (JRE seulement, non-root) ────────────────────────
# TODO 4 : image d'exécution (JRE 21, variante alpine)
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app

# TODO 5 : créer un utilisateur système « spring » d'UID 10001, puis basculer dessus
RUN addgroup -S spring && adduser -S -u 10001 -G spring spring
USER spring

# TODO 6 : récupérer le jar produit à l'étape « build » et le nommer app.jar
COPY --from=build /app/target/*.jar app.jar

# TODO 7 : port d'écoute documenté
EXPOSE 8080
ENV SERVER_PORT=8080

# TODO 8 : lancer le jar, avec une JVM qui dimensionne son heap à 75 % de la mémoire du conteneur
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "app.jar"]
